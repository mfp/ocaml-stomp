
open Printf
open OUnit

module STOMP = Mq_rabbitmq.Make_STOMP(Mq_concurrency.Posix_thread)
module M = Mq_impl.Make(Mq_concurrency.Posix_thread)(STOMP)

let login = ref "guest"
let passcode = ref "guest"
let addr = ref "127.0.0.1"
let port = ref 61613

let make_mq prefetch =
  M.make_tcp_message_queue ~prefetch ~login:!login ~passcode:!passcode !addr !port

let wrap_test ?(prefetch = 1) f () =
  let mq1, mq2 = make_mq prefetch, make_mq prefetch in
    Std.finally (fun () -> mq1#disconnect; mq2#disconnect) f (mq1, mq2)

let aeq_str ?msg exp act = assert_equal ?msg ~printer:(sprintf "%S") exp act

let check_message msg ~destination ~body =
  aeq_str ~msg:"destination" destination msg.Mq.msg_destination;
  aeq_str ~msg:"body" body msg.Mq.msg_body

let test_topic_send (mq1, mq2) =
  let destination = sprintf "testing-topic-%d" (Random.int 100000000) in
  let body = sprintf "testing-body-%d" (Random.int 100000000) in
    mq1#subscribe_topic destination;
    mq2#subscribe_topic destination;
    mq1#topic_send ?transaction:None ~destination body;
    let m1 = mq1#receive_msg in
    let m2 = mq2#receive_msg in
    let dst = "/topic/" ^ destination in
      check_message m1 dst body;
      check_message m2 dst body

let tests = "Mq high-level" >::: [
  "topic send" >:: wrap_test test_topic_send;
]

let _ = run_test_tt_main tests
