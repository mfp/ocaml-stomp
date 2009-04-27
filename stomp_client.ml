open ExtString

type received_msg = {
  msg_id : string;
  msg_headers : (string * string) list;
  msg_body : string
}

type stomp_error =
    Connection_closed
  | Protocol_error of (string * (string * string) list * string)

exception Stomp_error of string * stomp_error

module type S =
sig
  type 'a thread
  type connection
  type transaction
  type message_id

  val connect : Unix.sockaddr -> login:string -> password:string -> connection thread
  val disconnect : connection -> unit thread
  val send : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread
  val send_no_ack : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  val receive_msg : connection -> received_msg thread
  val ack_msg : connection -> ?transaction:transaction ->
    received_msg -> unit thread

  val subscribe : connection -> string -> unit thread
  val unsubscribe : connection -> string -> unit thread

  val transaction_begin : connection -> transaction thread
  val transaction_commit : connection -> transaction -> unit thread
  val transaction_commit_all : connection -> unit thread
  val transaction_abort_all : connection -> unit thread
  val transaction_abort : connection -> transaction -> unit thread
end

module Make(C : Concurrency_monad.CLIENT) =
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
  }

  let error err fmt = Printf.kprintf (fun s -> fail (Stomp_error (s, err))) fmt

  let establish_conn sockaddr =
    open_connection sockaddr >>= fun (c_in, c_out) ->
    return { c_in = c_in; c_out = c_out; c_closed = false; c_transactions = S.empty }

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

  let send_frame' conn command headers body =
    let oc ch c = output_char ch c in
    let ch = conn.c_out in
    output_string ch (command ^ "\n") >>= fun () ->
    output_headers ch headers >>= fun () ->
    oc ch '\n' >>= fun () ->
    output_string ch body >>= fun () ->
    oc ch '\000' >>= fun () ->
    flush ch

  let send_frame conn command headers body =
    let rid = receipt_id () in
    let headers = ("Receipt-Id", rid) :: headers in
      send_frame' conn command headers body >>= fun () ->
      return rid

  let send_frame_clength conn command headers body =
    send_frame conn command
      (("Content-length", string_of_int (String.length body)) :: headers) body

  let send_frame_clength' conn command headers body =
    send_frame' conn command
      (("Content-length", string_of_int (String.length body)) :: headers) body

  let read_headers ch =
    let rec loop acc = input_line ch >>= function
        "" -> return acc
      | s ->
          let k, v = String.split s ":" in
            loop ((String.lowercase k, String.strip v) :: acc)
    in loop []

  let receive_frame conn =
    let ch = conn.c_in in
      input_line ch >>= fun command ->
      print_endline ("Got command: " ^ command);
      let command = String.uppercase command in
      read_headers ch >>= fun headers ->
      try
        let len = int_of_string (List.assoc "content-length" headers) in
        (* FIXME: is the exception captured in the monad if bad len? *)
        let body = String.make len '\000' in
          really_input ch body 0 len >>= fun () ->
          input_char ch >>= fun _ -> (* FIXME: check that it's a \0? *)
          return (command, headers, body)
      with Not_found -> (* read until \0 *)
        let b = Buffer.create 80 in
        let rec loop () = input_char ch >>= function
            '\000' -> return (command, headers, Buffer.contents b)
          | c -> Buffer.add_char b c; loop ()
        in loop ()

  let connect sockaddr ~login ~password =
    establish_conn sockaddr >>= fun conn ->
    send_frame' conn "CONNECT" ["Login", login; "Password", password] "" >>= fun () ->
    receive_frame conn >>= function
        ("CONNECTED", _, _) -> return conn
      | t  -> error (Protocol_error t) "Stomp_client.connect"

  let disconnect conn =
    if conn.c_closed then return ()
    else begin
      send_frame' conn "DISCONNECT" [] "" >>= fun () ->
      close_in conn.c_in >>= fun () ->
      close_out conn.c_out >>= fun () ->
      conn.c_closed <- true;
      return ()
    end

  let check_closed msg conn =
    if conn.c_closed then error Connection_closed "Stomp_client.%s: closed connection" msg
    else return ()

  let header_is k v l =
    try
      List.assoc k l = v
    with Not_found -> false

  let transaction_header = function
      None -> []
    | Some t -> ["Transaction", t]

  let check_receipt msg conn rid =
    receive_frame conn >>= function
        ("RECEIPT", hs, _) when header_is "receipt-id" rid hs ->
          return ()
      | t -> error (Protocol_error t) "Stomp_client.%s: no RECEIPT received." msg

  let send_frame_with_receipt msg conn command hs body =
    check_closed msg conn >>= fun () ->
    send_frame conn command hs body >>= check_receipt msg conn

  let send_no_ack conn ?transaction ~destination body =
    check_closed "send_no_ack" conn >>= fun () ->
    let headers = ("Destination", destination) :: transaction_header transaction in
    send_frame_clength' conn "SEND" headers body

  let send conn ?transaction ~destination body =
    check_closed "send" conn >>= fun () ->
      (* if given a transaction ID, don't try to get RECEIPT --- the message
       * will only be saved on COMMIT anyway *)
      match transaction with
          None ->
            let headers = ["Destination", destination] in
              send_frame_clength conn "SEND" headers body >>= check_receipt "send" conn
        | _ ->
            let headers = ("Destination", destination) :: transaction_header transaction in
              send_frame_clength' conn "SEND" headers body

  let rec receive_msg conn =
    check_closed "receive_msg" conn >>= fun () ->
    receive_frame conn >>= function
        ("MESSAGE", hs, body) as t -> begin
          try
            let msg_id = List.assoc "message-id" hs in
              return { msg_id = msg_id; msg_headers = hs; msg_body = body }
          with Not_found ->
            error (Protocol_error t) "Stomp_client.receive_msg: no message-id."
        end
      | _ -> receive_msg conn (* try to get another frame *)

  let ack_msg conn ?transaction msg =
    let headers = ("Message-Id", msg.msg_id) :: transaction_header transaction in
    send_frame_with_receipt "ack_msg" conn "ACK" headers ""

  let subscribe conn s =
    send_frame_with_receipt "subscribe" conn
      "SUBSCRIBE" ["Destination", s; "Ack", "client"] ""

  let unsubscribe conn s =
    send_frame_with_receipt "subscribe" conn "UNSUBSCRIBE" ["Destination", s] ""

  let unsubscribe conn s =
    send_frame_with_receipt "unsubscribe" conn "UNSUBSCRIBE" ["Destination", s] ""

  let transaction_begin conn =
    let tid = transaction_id () in
    send_frame_with_receipt "transaction_begin" conn
      "BEGIN" ["Transaction", tid] "" >>= fun () ->
        conn.c_transactions <- S.add tid (conn.c_transactions);
        return tid

  let transaction_commit conn tid =
    send_frame_with_receipt "transaction_commit" conn
      "COMMIT" ["Transaction", tid] "" >>= fun () ->
    conn.c_transactions <- S.remove tid (conn.c_transactions);
    return ()

  let transaction_abort conn tid =
    send_frame_with_receipt "transaction_abort" conn
      "ABORT" ["Transaction", tid] "" >>= fun () ->
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
