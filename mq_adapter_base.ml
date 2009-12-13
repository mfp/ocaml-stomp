(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)

(** Basic STOMP adapter for ActimeMQ-style message queues. *)
module Make_STOMP(C : Mq_concurrency.THREAD) =
struct
  module B = Mq_stomp_client.Make_generic(C)
  module S = Set.Make(String)
  open C

  type 'a thread = 'a C.t
  type transaction = B.transaction
  type connection = {
    c_conn : B.connection;
    mutable c_topics : S.t;
    c_addr : Unix.sockaddr;
    c_login : string;
    c_passcode : string;
    c_prefetch : int option;
  }

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
    B.connect ~login ~passcode ~eof_nl:true addr >>= fun conn ->
    return {
      c_conn = conn; c_topics = S.empty;
      c_addr = addr; c_login = login; c_passcode = passcode;
      c_prefetch = prefetch;
    }

  let send conn ?transaction ?ack_timeout ~destination body =
    B.send conn.c_conn ?transaction
      ~headers:["persistent", "true"]
      ~destination:("/queue/" ^ destination) body

  let send_no_ack conn ?transaction ?ack_timeout ~destination body =
    B.send_no_ack conn.c_conn ?transaction
      ~headers:["persistent", "true"]
      ~destination:("/queue/" ^ destination) body

  let topic_send conn ?transaction ~destination body =
    B.send conn.c_conn ?transaction
      ~destination:("/topic/" ^ destination) body

  let topic_send_no_ack conn ?transaction ~destination body =
    B.send_no_ack conn.c_conn ?transaction
      ~destination:("/topic/" ^ destination) body

  let subscribe_queue conn ?(auto_delete = false) queue =
    B.subscribe conn.c_conn
      ~headers:["ack", "client"]
      ("/queue/" ^ queue)

  let unsubscribe_queue conn queue = B.unsubscribe conn.c_conn ("/queue/" ^ queue)

  let create_queue conn queue =
    (* no need to create it as a durable queue, unlike rabbitmq *)
    return ()

  let subscribe_topic conn topic =
    if S.mem topic conn.c_topics then return ()
    else
      let dst = "/topic/" ^ topic in
      let prefetch =
        Option.map (fun n -> ["prefetch", string_of_int n]) conn.c_prefetch
      in
        B.subscribe conn.c_conn ?headers:prefetch dst >>= fun () ->
        conn.c_topics <- S.add topic conn.c_topics;
        return ()

  let unsubscribe_topic conn topic =
    if not (S.mem topic conn.c_topics) then
      return ()
    else begin
      B.unsubscribe conn.c_conn ("/topic/" ^ topic) >>= fun () ->
      conn.c_topics <- S.remove topic conn.c_topics;
      return ()
    end

  let queue_size conn queue = return None
end
