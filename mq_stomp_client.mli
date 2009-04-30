module Make_generic : functor (C : Mq_concurrency.THREAD) ->
  Mq.GENERIC with type 'a thread = 'a C.t

module Make_rabbitmq : functor (C : Mq_concurrency.THREAD) ->
  Mq.HIGH_LEVEL with type 'a thread = 'a C.t
