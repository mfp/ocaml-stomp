(** {!Mq.HIGH_LEVEL} client for ActiveMQ STOMP servers.  Refer to
  * {!Mq_stomp_client} for information on usage in concurrent settings. *)
module Make_STOMP : functor (C : Mq_concurrency.THREAD) ->
sig
  include Mq.HIGH_LEVEL with type 'a thread = 'a C.t
end
