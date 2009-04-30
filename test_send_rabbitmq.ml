open Arg
open Printf

module S = Mq_rabbitmq.Make_STOMP(Mq_concurrency.Posix_thread)

let () = Random.self_init ()

let port = ref 61613
let address = ref "127.0.0.1"
let num_msgs = ref 0
let dest = ref (sprintf "test-%d" (Random.int 100000000))
let login = ref ""
let passcode = ref ""
let is_topic = ref false
let use_transaction = ref false

let msg = "Usage: test_send_rabbitmq -n N [options]"

let args =
  Arg.align
    [
      "-n", Set_int num_msgs, sprintf "N Send N messages.";
      "-a", Set_string address, sprintf "ADDRESS Address (default: %s-0)" !address;
      "-d", Set_string dest, sprintf "DEST Send to DEST (default: %s)" !dest;
      "-p", Set_int port, sprintf "PORT Port (default: %d)" !port;
      "--login", Set_string login, "LOGIN Use the given login (default: none).";
      "--passcode", Set_string passcode, "PASSCODE Use the given passcode (default: none).";
      "--topic", Set is_topic, " Send as a topic message (default: no).";
      "--transaction", Set use_transaction, " Send all messages in a transaction.";
    ]

let () =
  Arg.parse args ignore msg;
  if !num_msgs <= 0 then begin
    Arg.usage args msg;
    exit 1;
  end;
  let c = S.connect !login !passcode
            (Unix.ADDR_INET (Unix.inet_addr_of_string !address, !port)) in
  let transaction = match !use_transaction with
      true -> Some (S.transaction_begin c)
    | false -> None
  in
    printf "Sending to %s\n" !dest;
    for i = 1 to !num_msgs do
      let msg = sprintf "message number %d" i in
        printf "\r%d%!" i;
        if !is_topic then
          S.topic_send_no_ack c ?transaction ~destination:!dest msg
        else
          S.send_no_ack c ?transaction ~destination:!dest msg
    done;
    print_newline ();
    S.transaction_commit_all c;
    S.disconnect c
