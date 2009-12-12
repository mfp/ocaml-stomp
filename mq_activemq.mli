(** {!Mq.HIGH_LEVEL} client for ActiveMQ STOMP servers.  Refer to
  * {!Mq_stomp_client} for information on usage in concurrent settings. *)
module Make_STOMP : functor (C : Mq_concurrency.THREAD) ->
sig
  include Mq.HIGH_LEVEL with type 'a thread = 'a C.t
                         and type transaction = Mq_stomp_client.Make_generic(C).transaction
  val get_stomp_connection : connection -> Mq_stomp_client.Make_generic(C).connection
end
