open Printf
open Mq

module Uuid =
struct

  let rng = Cryptokit.Random.device_rng "/dev/urandom"

  type t = string

  let create () =
    let s = String.create 16 in
      rng#random_bytes s 0 (String.length s);
      s

  let base64_to_base64url = function
      '+' -> '-'
    | '/' -> '_'
    | c -> c

  let to_base64url uuid =
    let s = Cryptokit.transform_string (Cryptokit.Base64.encode_compact ()) uuid in
      for i = 0 to String.length s - 1 do
        s.[i] <- base64_to_base64url s.[i]
      done;
      s
end

module Make_STOMP(C : Mq_concurrency.THREAD) =
struct
  module B = Mq_stomp_client.Make_generic(C)
  module M = Map.Make(String)
  open C

  type 'a thread = 'a C.t
  type transaction = B.transaction
  type connection = {
    c_conn : B.connection;
    mutable c_topic_ids : string M.t;
    c_addr : Unix.sockaddr;
    c_login : string;
    c_passcode : string;
  }

  let make_topic_id =
    let i = ref 0 in fun () -> incr i; sprintf "topic-%d" !i

  let delegate f t = f t.c_conn

  let transaction_begin = delegate B.transaction_begin
  let transaction_commit = delegate B.transaction_commit
  let transaction_commit_all = delegate B.transaction_commit_all
  let transaction_abort_all = delegate B.transaction_abort_all
  let transaction_abort = delegate B.transaction_abort

  let receive_msg = delegate B.receive_msg
  let ack_msg = delegate B.ack_msg
  let ack = delegate B.ack

  let disconnect = delegate B.disconnect

  let connect ?prefetch ~login ~passcode addr =
    let headers = match prefetch with
        None -> []
      | Some n -> ["prefetch", string_of_int n]
    in
      B.connect ~headers ~login ~passcode ~eof_nl:false addr >>= fun conn ->
      return {
        c_conn = conn; c_topic_ids = M.empty;
        c_addr = addr; c_login = login; c_passcode = passcode;
      }

  let normal_headers = ["content-type", "application/octet-stream"]
  let topic_headers = ["exchange", "amq.topic"] @ normal_headers

  let send conn ?transaction ~destination body =
    B.send conn.c_conn ?transaction
      ~headers:normal_headers
      ~destination:("/queue/" ^ destination) body

  let send_no_ack conn ?transaction ~destination body =
    B.send_no_ack conn.c_conn ?transaction
      ~headers:normal_headers
      ~destination:("/queue/" ^ destination) body

  let topic_send conn ?transaction ~destination body =
    B.send conn.c_conn ?transaction
      ~headers:topic_headers
      ~destination:("/topic/" ^ destination) body

  let topic_send_no_ack conn ?transaction ~destination body =
    B.send_no_ack conn.c_conn ?transaction
      ~headers:topic_headers
      ~destination:("/topic/" ^ destination) body

  let subscribe_queue conn ?(auto_delete = false) queue =
    B.subscribe conn.c_conn
      ~headers:["auto-delete", string_of_bool auto_delete;
                "durable", "true"; "ack", "client"]
      ("/queue/" ^ queue)

  let unsubscribe_queue conn queue = B.unsubscribe conn.c_conn ("/queue/" ^ queue)

  let rec create_queue conn queue =
    let rec try_to_create c =
      (* subscribe to the queue in another connection, don't ACK the received
       * msg, if any *)
      catch
        (fun () -> subscribe_queue c queue >>= fun () -> disconnect c)
        (function
             (* FIXME: limit number of attempts? *)
           | Message_queue_error (Retry, _, _) -> try_to_create c
           | Message_queue_error (Reconnect, _, _) -> create_queue conn queue
           | e -> fail e)
    in connect conn.c_addr ~prefetch:1
         ~login:conn.c_login ~passcode:conn.c_passcode >>= try_to_create

  let subscribe_topic conn topic =
    if M.mem topic conn.c_topic_ids then return ()
    else
      let id = make_topic_id () in
      let dst = "/topic/" ^ topic in
        B.subscribe conn.c_conn
          ~headers:["exchange", "amq.topic"; "routing_key", dst; "id", id]
          (Uuid.to_base64url (Uuid.create ())) >>= fun () ->
        conn.c_topic_ids <- M.add topic id conn.c_topic_ids;
        return ()

  let unsubscribe_topic conn topic =
    match (try Some (M.find topic conn.c_topic_ids) with Not_found -> None) with
        None -> return ()
      | Some id ->
          B.unsubscribe conn.c_conn ~headers:["id", id] ("/topic/" ^ topic)
end
