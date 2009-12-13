(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)

module Make_STOMP(CONC : Mq_concurrency.THREAD) =
struct
  include Mq_adapter_base.Make_STOMP(CONC)

  let prefetch_headers conn =
    Option.map_default
      (fun n -> ["activemq.prefetchSize", string_of_int n]) [] conn.c_prefetch

  let subscribe_queue conn ?(auto_delete = false) queue =
    subscribe_queue_aux
      ~headers:(("ack", "client") :: prefetch_headers conn)
      conn ~auto_delete queue
end
