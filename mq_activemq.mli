
module Make_STOMP : functor (C : Mq_concurrency.THREAD) ->
  Mq.HIGH_LEVEL with type 'a thread = 'a C.t
