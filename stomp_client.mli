module Make_generic : functor (C : Concurrency_monad.THREAD) ->
  Message_queue.GENERIC with type 'a thread = 'a C.t

module Make_rabbitmq : functor (C : Concurrency_monad.THREAD) ->
  Message_queue.HIGH_LEVEL with type 'a thread = 'a C.t
