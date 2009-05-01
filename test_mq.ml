
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

let wrap_test2 ?(prefetch = 1) f () =
  let mq1, mq2 = make_mq prefetch, make_mq prefetch in
    Std.finally (fun () -> mq1#disconnect; mq2#disconnect) f (mq1, mq2)

let wrap_test3 ?(prefetch = 1) f () =
  let mq1, mq2, mq3 = make_mq prefetch, make_mq prefetch, make_mq prefetch in
    Std.finally (fun () -> mq1#disconnect; mq2#disconnect; mq3#disconnect)
      f (mq1, mq2, mq3)

let aeq_str ?msg exp act = assert_equal ?msg ~printer:(sprintf "%S") exp act

let aeq_str_list ?msg exp act =
  assert_equal ?msg
    ~printer:(fun l -> "[" ^ String.concat "; " (List.map (sprintf "%S") l) ^ "]")
    exp act

let check_message msg ~destination ~body =
  aeq_str ~msg:"destination" destination msg.Mq.msg_destination;
  aeq_str ~msg:"body" body msg.Mq.msg_body

let random_topic () = sprintf "testing-topic-%d" (Random.int 100000000)

let random_body () = sprintf "testing-body-%d" (Random.int 100000000)

let test_topic_send ((mq1, mq2) : _ #M.mq * _ #M.mq) =
  let destination = random_topic () in
  let body = random_body () in
    mq1#subscribe_topic destination;
    mq2#subscribe_topic destination;
    mq1#topic_send ~destination body;
    mq2#topic_send ~destination body;
    let m1 = mq1#receive_msg in
    let m2 = mq2#receive_msg in
    let dst = "/topic/" ^ destination in
      check_message m1 dst body;
      check_message m2 dst body

let test_topic_sends ((mq1, mq2, mq3) : _ #M.mq * _ #M.mq * _ #M.mq) =
  let num_msgs = 1000 in
  let destination = random_topic () in
  let bodies = List.sort String.compare
                 (Array.to_list (Array.init num_msgs (fun _ -> random_body ())))
  in
    mq2#subscribe_topic destination;
    mq3#subscribe_topic destination;
    List.iter (mq1#topic_send ~destination) bodies;
    let recvd2 = ref [] in
    let recvd3 = ref [] in
      for i = 1 to List.length bodies do
        recvd2 := mq2#receive_msg.Mq.msg_body :: !recvd2
      done;
      for i = 1 to List.length bodies do
        recvd3 := mq3#receive_msg.Mq.msg_body :: !recvd3
      done;
      aeq_str_list bodies (List.sort String.compare !recvd2);
      aeq_str_list bodies (List.sort String.compare !recvd3)

let tests = "Mq high-level" >::: [
  "topic send" >:: wrap_test2 test_topic_send;
  "multiple topic sends" >:: wrap_test3 test_topic_sends;
]

let _ = run_test_tt_main tests
