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

module type BASIC =
sig
  type 'a thread
  type connection
  type transaction
  type message_id

  val connect : ?login:string -> ?passcode:string -> ?eof_nl:bool ->
    ?headers:(string * string) list -> Unix.sockaddr -> connection thread
  val disconnect : connection -> unit thread
  val send : connection -> ?transaction:transaction -> ?persistent:bool ->
    destination:string -> ?headers:(string * string) list -> string -> unit thread
  val send_no_ack : connection -> ?transaction:transaction ->
    destination:string -> ?headers:(string * string) list -> string -> unit thread

  val receive_msg : connection -> received_msg thread
  val ack_msg : connection -> ?transaction:transaction -> received_msg -> unit thread

  val subscribe : connection -> ?headers:(string * string) list -> string -> unit thread
  val unsubscribe : connection -> ?headers:(string * string) list -> string -> unit thread

  val transaction_begin : connection -> transaction thread
  val transaction_commit : connection -> transaction -> unit thread
  val transaction_commit_all : connection -> unit thread
  val transaction_abort_all : connection -> unit thread
  val transaction_abort : connection -> transaction -> unit thread
end

module Make(C : Concurrency_monad.THREAD) =
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
  }

  let error err fmt = Printf.kprintf (fun s -> fail (Stomp_error (s, err))) fmt

  let establish_conn sockaddr eof_nl =
    open_connection sockaddr >>= fun (c_in, c_out) ->
    return { c_in = c_in; c_out = c_out; c_closed = false; c_transactions = S.empty;
             c_eof_nl = eof_nl; }

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
    let ch = conn.c_out in
    output_string ch (command ^ "\n") >>= fun () ->
    output_headers ch headers >>= fun () ->
    output_char ch '\n' >>= fun () ->
    output_string ch body >>= fun () ->
    output_string ch "\000\n" >>= fun () ->
    flush ch

  let send_frame conn command headers body =
    let rid = receipt_id () in
    let headers = ("receipt", rid) :: headers in
      send_frame' conn command headers body >>= fun () ->
      return rid

  let send_frame_clength conn command headers body =
    send_frame conn command
      (("content-length", string_of_int (String.length body)) :: headers) body

  let send_frame_clength' conn command headers body =
    send_frame' conn command
      (("content-length", string_of_int (String.length body)) :: headers) body

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

  let connect ?login ?passcode ?(eof_nl = true) ?(headers = []) sockaddr =
    establish_conn sockaddr eof_nl >>= fun conn ->
    let headers = match login, passcode with
        None, None -> headers
      | _ -> ("login", Option.default "" login) ::
             ("passcode", Option.default "" passcode) :: headers in
    send_frame' conn "CONNECT" headers "" >>= fun () ->
    receive_frame conn >>= function
        ("CONNECTED", _, _) -> return conn
      | t  -> error (Protocol_error t) "Stomp_client.connect"

  let disconnect conn =
    if conn.c_closed then return ()
    else begin
      send_frame' conn "DISCONNECT" [] "" >>= fun () ->
      close_in conn.c_in >>= fun () ->
      (* closing one way can cause the other side to close this too *)
      catch (fun () -> close_out conn.c_out) (fun e -> return ()) >>= fun () ->
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
    | Some t -> ["transaction", t]

  let check_receipt msg conn rid =
    receive_frame conn >>= function
        ("RECEIPT", hs, _) when header_is "receipt-id" rid hs ->
          return ()
      | t -> error (Protocol_error t) "Stomp_client.%s: no RECEIPT received." msg

  let send_frame_with_receipt msg conn command hs body =
    check_closed msg conn >>= fun () ->
    send_frame conn command hs body >>= check_receipt msg conn

  let send_headers transaction persistent destination =
    ("destination", destination) :: ("persistent", string_of_bool persistent) ::
    transaction_header transaction

  let send_no_ack conn ?transaction ~destination ?(headers = []) body =
    check_closed "send_no_ack" conn >>= fun () ->
    let headers = headers @ send_headers transaction false destination in
    send_frame_clength' conn "SEND" headers body

  let send conn ?transaction ?(persistent = true) ~destination ?(headers = []) body =
    check_closed "send" conn >>= fun () ->
    let headers = headers @ send_headers transaction persistent destination in
      (* if given a transaction ID, don't try to get RECEIPT --- the message
       * will only be saved on COMMIT anyway *)
      match transaction with
          None -> send_frame_clength conn "SEND" headers body >>= check_receipt "send" conn
        | _ -> send_frame_clength' conn "SEND" headers body

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
    let headers = ("message-id", msg.msg_id) :: transaction_header transaction in
    send_frame_with_receipt "ack_msg" conn "ACK" headers ""

  let subscribe conn ?(headers = []) s =
    send_frame_with_receipt "subscribe" conn
      "SUBSCRIBE" (headers @ ["destination", s; "ack", "client"]) ""

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
