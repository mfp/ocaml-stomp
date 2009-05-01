open ExtString
open Printf
open Mq

module Make_generic(C : Mq_concurrency.THREAD) =
struct
  module S = Set.Make(String)
  open C

  type 'a thread = 'a C.t
  type transaction = string
  type message_id = string

  type connection = {
    c_in : in_channel;
    c_out : out_channel;
    mutable c_closed : bool;
    mutable c_transactions : S.t;
    c_eof_nl : bool;
    c_pending_msgs : received_msg Queue.t;
  }

  let error restartable err fmt =
    Printf.kprintf (fun s -> fail (Message_queue_error (restartable, s, err))) fmt

  let rec output_headers ch = function
      [] -> return ()
    | (name, value) :: tl ->
        output_string ch (name ^ ": ") >>= fun () ->
        output_string ch value >>= fun () ->
        output_char ch '\n' >>= fun () ->
        output_headers ch tl

  let receipt_id =
    let i = ref 1 in fun () -> incr i; Printf.sprintf "receipt-%d" !i

  let transaction_id =
    let i = ref 1 in fun () -> incr i; Printf.sprintf "transaction-%d" !i

  let send_frame' msg conn command headers body =
    let ch = conn.c_out in
      catch
        (fun () ->
           output_string ch (command ^ "\n") >>= fun () ->
           output_headers ch headers >>= fun () ->
           output_char ch '\n' >>= fun () ->
           output_string ch body >>= fun () ->
           output_string ch "\000\n" >>= fun () ->
           flush ch)
        (* FIXME: handle errors besides Sys_error differenty? *)
        (fun _ -> error Reconnect (Connection_error Closed) "Mq_stomp_client.%s" msg)

  let send_frame msg conn command headers body =
    let rid = receipt_id () in
    let headers = ("receipt", rid) :: headers in
      send_frame' msg conn command headers body >>= fun () ->
      return rid

  let send_frame_clength msg conn command headers body =
    send_frame msg conn command
      (("content-length", string_of_int (String.length body)) :: headers) body

  let send_frame_clength' msg conn command headers body =
    send_frame' msg conn command
      (("content-length", string_of_int (String.length body)) :: headers) body

  let read_headers ch =
    let rec loop acc = input_line ch >>= function
        "" -> return acc
      | s ->
          let k, v = String.split s ":" in
            loop ((String.lowercase k, String.strip v) :: acc)
    in loop []


  let rec read_command ch = input_line ch >>= function
      "" -> read_command ch
    | l -> return l

  let receive_frame conn =
    let ch = conn.c_in in
      read_command ch >>= fun command ->
      let command = String.uppercase (String.strip command) in
      read_headers ch >>= fun headers ->
      try
        let len = int_of_string (List.assoc "content-length" headers) in
        (* FIXME: is the exception captured in the monad if bad len? *)
        let body = String.make len '\000' in
          really_input ch body 0 len >>= fun () ->
            if conn.c_eof_nl then begin
              input_line ch >>= fun _ -> (* FIXME: check that it's a \0\n ? *)
              return (command, headers, body)
            end else begin
              input_char ch >>= fun _ -> (* FIXME: check that it's a \0 ? *)
              return (command, headers, body)
            end
      with Not_found -> (* read until \0 *)
        let rec nl_loop ch b =
          input_line ch >>= function
              "" -> Buffer.add_char b '\n'; nl_loop ch b
            | line when line.[String.length line - 1] = '\000' ->
                Buffer.add_substring b line 0 (String.length line - 1);
                return (Buffer.contents b)
            | line ->
                Buffer.add_string b line; Buffer.add_char b '\n'; nl_loop ch b in
        let rec no_nl_loop ch b =
          input_char ch >>= function
              '\000' -> return (Buffer.contents b)
            | c -> Buffer.add_char b c; no_nl_loop ch b in
        let read_f = if conn.c_eof_nl then nl_loop else no_nl_loop in
          read_f ch (Buffer.create 80) >>= fun body ->
          return (command, headers, body)

  (* add EOF handling *)
  let receive_frame msg conn =
    catch
      (fun () -> receive_frame conn)
      (function
           Sys_error _ | End_of_file ->
               error Reconnect (Connection_error Closed) "Mq_stomp_client.%s" msg
         | e -> fail e)

  let rec receive_non_message_frame msg conn =
    receive_frame msg conn >>= function
        ("MESSAGE", hs, body) ->
          begin
            try
              Queue.add
                { msg_id = List.assoc "message-id" hs;
                  msg_destination = List.assoc "destination" hs;
                  msg_headers = hs; msg_body = body }
                conn.c_pending_msgs
            with Not_found -> (* no message-id or destination, ignore *) ()
          end;
          receive_non_message_frame msg conn
      | frame -> return frame

  let establish_conn msg sockaddr eof_nl =
    catch
      (fun () -> open_connection sockaddr)
      (function
           Unix.Unix_error (Unix.ECONNREFUSED, _, _) ->
             error Abort (Connection_error Connection_refused) msg
         | e -> fail e)
    >>= fun (c_in, c_out) ->
    return { c_in = c_in; c_out = c_out; c_closed = false; c_transactions = S.empty;
             c_eof_nl = eof_nl; c_pending_msgs = Queue.create () }

  let header_is k v l =
    try
      List.assoc k l = v
    with Not_found -> false

  let connect ?login ?passcode ?(eof_nl = true) ?(headers = []) sockaddr =
    establish_conn "Mq_stomp_client.connect" sockaddr eof_nl >>= fun conn ->
    let headers = match login, passcode with
        None, None -> headers
      | _ -> ("login", Option.default "" login) ::
             ("passcode", Option.default "" passcode) :: headers in
    send_frame' "connect" conn "CONNECT" headers "" >>= fun () ->
    receive_non_message_frame "connect" conn >>= function
        ("CONNECTED", _, _) -> return conn
      | ("ERROR", hs, _) when header_is "message" "access_refused" hs ->
          error Abort (Connection_error Access_refused) "Mq_stomp_client.connect"
      | t  -> error Reconnect (Protocol_error t) "Mq_stomp_client.connect"

  let disconnect conn =
    if conn.c_closed then return ()
    else
      catch
        (fun () ->
           send_frame' "disconnect" conn "DISCONNECT" [] "" >>= fun () ->
           close_in_noerr conn.c_in >>= fun () -> close_out_noerr conn.c_out >>= fun () ->
           conn.c_closed <- true;
           return ())
        (function
             (* if there's a connection error, such as the other end closing
              * before us, ignore it, as we wanted to close the conn anyway *)
             Message_queue_error (_, _, Connection_error _) -> return ()
           | e -> fail e)

  let check_closed msg conn =
    if conn.c_closed then
      error Reconnect (Connection_error Closed)
        "Mq_stomp_client.%s: closed connection" msg
    else return ()

  let transaction_header = function
      None -> []
    | Some t -> ["transaction", t]

  let check_receipt msg conn rid =
    receive_non_message_frame msg conn >>= function
        ("RECEIPT", hs, _) when header_is "receipt-id" rid hs ->
          return ()
      | t -> error Reconnect (Protocol_error t) "Mq_stomp_client.%s: no RECEIPT received." msg

  let send_frame_with_receipt msg conn command hs body =
    check_closed msg conn >>= fun () ->
    send_frame msg conn command hs body >>= check_receipt msg conn

  let send_headers transaction persistent destination =
    ("destination", destination) :: ("persistent", string_of_bool persistent) ::
    transaction_header transaction

  let send_no_ack conn ?transaction ~destination ?(headers = []) body =
    check_closed "send_no_ack" conn >>= fun () ->
    let headers = headers @ send_headers transaction false destination in
    send_frame_clength' "send_no_ack" conn "SEND" headers body

  let send conn ?transaction ?(persistent = true) ~destination ?(headers = []) body =
    check_closed "send" conn >>= fun () ->
    let headers = headers @ send_headers transaction persistent destination in
      (* if given a transaction ID, don't try to get RECEIPT --- the message
       * will only be saved on COMMIT anyway *)
      match transaction with
          None ->
            send_frame_clength "send" conn "SEND" headers body >>=
            check_receipt "send" conn
        | _ ->
            send_frame_clength' "send" conn "SEND" headers body

  let rec receive_msg conn =
    check_closed "receive_msg" conn >>= fun () ->
    try
      return (Queue.take conn.c_pending_msgs)
    with Queue.Empty ->
      receive_frame "receive_msg" conn >>= function
          ("MESSAGE", hs, body) as t -> begin
            try
              return { msg_id = List.assoc "message-id" hs;
                       msg_destination = List.assoc "destination" hs;
                       msg_headers = hs;
                       msg_body = body; }
            with Not_found ->
              error Retry (Protocol_error t)
                "Mq_stomp_client.receive_msg: no message-id or destination."
          end
        | _ -> receive_msg conn (* try to get another frame *)

  let ack_msg conn ?transaction msg =
    let headers = ("message-id", msg.msg_id) :: transaction_header transaction in
    send_frame_with_receipt "ack_msg" conn "ACK" headers ""

  let subscribe conn ?(headers = []) s =
    send_frame_with_receipt "subscribe" conn
      "SUBSCRIBE" (headers @ ["destination", s]) ""

  let unsubscribe conn ?(headers = []) s =
    send_frame_with_receipt "subscribe" conn "UNSUBSCRIBE" (headers @ ["destination", s]) ""

  let transaction_begin conn =
    let tid = transaction_id () in
    send_frame_with_receipt "transaction_begin" conn
      "BEGIN" ["transaction", tid] "" >>= fun () ->
        conn.c_transactions <- S.add tid (conn.c_transactions);
        return tid

  let transaction_commit conn tid =
    send_frame_with_receipt "transaction_commit" conn
      "COMMIT" ["transaction", tid] "" >>= fun () ->
    conn.c_transactions <- S.remove tid (conn.c_transactions);
    return ()

  let transaction_abort conn tid =
    send_frame_with_receipt "transaction_abort" conn
      "ABORT" ["transaction", tid] "" >>= fun () ->
    conn.c_transactions <- S.remove tid (conn.c_transactions);
    return ()

  let transaction_for_all f conn =
    let rec loop s =
      let next =
        try
          let tid = S.min_elt s in
            f conn tid >>= fun () ->
            return (Some conn.c_transactions)
        with Not_found -> (* empty *)
          return None
      in next >>= function None -> return () | Some s -> loop s
    in loop conn.c_transactions

  let transaction_commit_all = transaction_for_all transaction_commit
  let transaction_abort_all = transaction_for_all transaction_abort
end
