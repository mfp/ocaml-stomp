(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)

module Make_STOMP(CONC : Mq_concurrency.THREAD) =
struct
  open CONC
  include Mq_adapter_base.Make_STOMP(CONC)

  let control_msg_aux conn dest f field =
    let c = conn.c_conn in
    let rid = B.receipt_id () in
      B.expect_receipt c rid;
      B.send_no_ack c
        ~headers:["receipt", rid]
        ~destination:("/control/" ^ dest) "" >>= fun () ->
      B.receive_receipt c rid >>= fun r ->
        try
          return (Some (f (List.assoc field r.B.r_headers)))
        with _ -> return None

  let queue_size conn queue =
    control_msg_aux conn ("count-msgs/queue/" ^ queue) Int64.of_string "num-messages"

  let queue_subscribers conn queue =
    control_msg_aux conn
      ("count-subscribers/queue/" ^ queue) int_of_string "num-subscribers"

  let topic_subscribers conn topic =
    control_msg_aux conn
      ("count-subscribers/topic/" ^ topic) int_of_string "num-subscribers"

  let timeout_headers =
    Option.map_default (fun timeout -> ["ack-timeout", string_of_float timeout]) []

  let prefetch_headers conn =
    Option.map_default
      (fun n -> ["prefetch", string_of_int n]) [] conn.c_prefetch

  let subscribe_queue conn ?(auto_delete = false) queue =
    subscribe_queue_aux
      ~headers:(("ack", "client") :: prefetch_headers conn)
      conn ~auto_delete queue

  let send conn ?transaction ?ack_timeout ~destination body =
    B.send conn.c_conn ?transaction
      ~headers:(timeout_headers ack_timeout)
      ~destination:("/queue/" ^ destination) body

  let send_no_ack conn ?transaction ?ack_timeout ~destination body =
    B.send_no_ack conn.c_conn ?transaction
      ~headers:(timeout_headers ack_timeout)
      ~destination:("/queue/" ^ destination) body
end
