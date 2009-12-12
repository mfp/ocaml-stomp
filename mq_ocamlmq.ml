(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)

module Make_STOMP(CONC : Mq_concurrency.THREAD) =
struct
  open CONC
  include Mq_activemq.Make_STOMP(CONC)
  module B = Mq_stomp_client.Make_generic(CONC)

  let queue_size conn queue =
    let c = get_stomp_connection conn in
    let rid = B.receipt_id () in
      B.expect_receipt c rid;
      B.send_no_ack c
        ~headers:["receipt", rid]
        ~destination:("/control/count-msgs/" ^ queue) "" >>= fun () ->
      B.receive_receipt c rid >>= fun r ->
        try
          return (Some (Int64.of_string (List.assoc "num-messages" r.B.r_headers)))
        with _ -> return None
end
