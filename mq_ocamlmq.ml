(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)

module Make_STOMP(CONC : Mq_concurrency.THREAD) =
struct
  open CONC
  include Mq_adapter_base.Make_STOMP(CONC)

  let queue_size conn queue =
    let c = conn.c_conn in
    let rid = B.receipt_id () in
      B.expect_receipt c rid;
      B.send_no_ack c
        ~headers:["receipt", rid]
        ~destination:("/control/count-msgs/queue/" ^ queue) "" >>= fun () ->
      B.receive_receipt c rid >>= fun r ->
        try
          return (Some (Int64.of_string (List.assoc "num-messages" r.B.r_headers)))
        with _ -> return None

  let timeout_headers =
    Option.map_default (fun timeout -> ["ack-timeout", string_of_float timeout]) []

  let send conn ?transaction ?ack_timeout ~destination body =
    B.send conn.c_conn ?transaction
      ~headers:(timeout_headers ack_timeout)
      ~destination:("/queue/" ^ destination) body

  let send_no_ack conn ?transaction ?ack_timeout ~destination body =
    B.send_no_ack conn.c_conn ?transaction
      ~headers:(timeout_headers ack_timeout)
      ~destination:("/queue/" ^ destination) body
end
