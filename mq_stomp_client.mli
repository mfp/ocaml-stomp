(** {!Mq.GENERIC} STOMP protocol client. *)
module Make_generic : functor (C : Mq_concurrency.THREAD) ->
sig
  type receipt = {
    r_headers : (string * string) list;
    r_body : string;
  }
  include Mq.GENERIC with type 'a thread = 'a C.t

  (** [expect_receipt conn rid] notifies that receipts whose receipt-id is
    * [rid] are to be stored and will be consumed with [receive_receipt]. *)
  val expect_receipt : connection -> string -> unit

  (** [receive_receipt conn rid] blocks until a RECEIPT with the given
    * receipt-id is received. You must use [expect_receipt] before, or the
    * RECEIPT might be discarded (resulting in receive_receipt blocking
    * forever). *)
  val receive_receipt : connection -> string -> receipt thread

  (** Return a unique receipt id. *)
  val receipt_id : unit -> string
  (** Return a unique transaction id. *)
  val transaction_id : unit -> string
end
