(** {!Mq.GENERIC} STOMP protocol client. *)
module Make_generic : functor (C : Mq_concurrency.THREAD) ->
  Mq.GENERIC with type 'a thread = 'a C.t
