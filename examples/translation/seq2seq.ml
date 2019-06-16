(* Translation with a Sequence to Sequence Model and Attention.

   This follows the line of the PyTorch tutorial:
   https://pytorch.org/tutorials/intermediate/seq2seq_translation_tutorial.html

   The dataset can be downloaded from the following link:
   https://download.pytorch.org/tutorial/data.zip
   The eng-fra.txt file should be moved in the data directory.
*)
open! Base
open Torch

let max_length = 10

module Encoder : sig
  type t
  type state

  val create : Var_store.t -> input_size:int -> hidden_size:int -> t
  val forward : t -> Tensor.t -> state -> state * Tensor.t
  val zero_state : t -> state
  val to_tensor : state -> Tensor.t
end = struct
  type state = Tensor.t
  type t = (Tensor.t -> state -> state * Tensor.t) * state

  let create vs ~input_size ~hidden_size =
    let embedding =
      Layer.embeddings vs ~num_embeddings:input_size ~embedding_dim:hidden_size
    in
    let gru = Layer.Gru.create vs ~input_dim:hidden_size ~hidden_size in
    let forward input_ hidden =
      let hidden =
        Layer.forward embedding input_
        |> Tensor.view ~size:[ 1; -1 ]
        |> Layer.Gru.step gru hidden
      in
      hidden, hidden
    in
    forward, Layer.Gru.zero_state gru ~batch_size:1

  let forward = fst
  let zero_state = snd
  let to_tensor = Fn.id
end

(* Decoder without attention. *)
module Decoder : sig
  type t
  type state

  val create : Var_store.t -> hidden_size:int -> output_size:int -> t
  val forward : t -> Tensor.t -> state -> state * Tensor.t
  val zero_state : t -> state
  val of_tensor : Tensor.t -> state
end = struct
  type state = Tensor.t
  type t = (Tensor.t -> state -> state * Tensor.t) * state

  let create vs ~hidden_size ~output_size =
    let embedding =
      Layer.embeddings vs ~num_embeddings:output_size ~embedding_dim:hidden_size
    in
    let gru = Layer.Gru.create vs ~input_dim:hidden_size ~hidden_size in
    let linear = Layer.linear vs ~input_dim:hidden_size output_size in
    let forward input_ hidden =
      let hidden =
        Layer.forward embedding input_
        |> Tensor.view ~size:[ 1; -1 ]
        |> Tensor.relu
        |> Layer.Gru.step gru hidden
      in
      hidden, Layer.forward linear hidden |> Tensor.softmax ~dim:(-1)
    in
    forward, Layer.Gru.zero_state gru ~batch_size:1

  let forward = fst
  let zero_state = snd
  let of_tensor = Fn.id
end

let predict ~input_ ~encoder ~decoder ~decoder_start ~decoder_eos =
  let encoder_final, encoder_outputs =
    List.fold_map input_ ~init:(Encoder.zero_state encoder) ~f:(fun state idx ->
        let input_tensor = Tensor.of_int1 [| idx |] in
        Encoder.forward encoder input_tensor state)
  in
  let _encoder_outputs = Tensor.stack encoder_outputs ~dim:0 in
  let decoder_state = Encoder.to_tensor encoder_final |> Decoder.of_tensor in
  let rec loop ~state ~prevs ~max_length =
    let state, output = Decoder.forward decoder (List.hd_exn prevs) state in
    let _, output = Tensor.topk output ~k:1 ~dim:(-1) ~largest:true ~sorted:true in
    if Tensor.to_int0_exn output = decoder_eos || max_length = 0
    then List.rev prevs
    else loop ~state ~prevs:(output :: prevs) ~max_length:(max_length - 1)
  in
  loop ~state:decoder_state ~prevs:[ decoder_start ] ~max_length

let train_loss ~input_ ~target ~encoder ~decoder ~decoder_start ~decoder_eos =
  let encoder_final, encoder_outputs =
    List.fold_map input_ ~init:(Encoder.zero_state encoder) ~f:(fun state idx ->
        let input_tensor = Tensor.of_int1 [| idx |] in
        Encoder.forward encoder input_tensor state)
  in
  let _encoder_outputs = Tensor.stack encoder_outputs ~dim:0 in
  let use_teacher_forcing = Float.( < ) (Random.float 1.) 0.5 in
  let decoder_state = Encoder.to_tensor encoder_final |> Decoder.of_tensor in
  let rec loop ~loss ~state ~prev ~target =
    match target with
    | [] -> loss
    | idx :: target ->
      let state, output = Decoder.forward decoder prev state in
      let target_tensor = Tensor.of_int1 [| idx |] in
      let loss = Tensor.(loss + nll_loss output ~targets:target_tensor) in
      let _, output = Tensor.topk output ~k:1 ~dim:(-1) ~largest:true ~sorted:true in
      if Tensor.to_int0_exn output = decoder_eos
      then loss
      else (
        let prev = if use_teacher_forcing then target_tensor else output in
        loop ~loss ~state ~prev ~target)
  in
  loop ~loss:(Tensor.of_float0 0.) ~state:decoder_state ~prev:decoder_start ~target

let hidden_size = 256

module Loss_stats = struct
  (* TODO: also track time elapsed ? *)
  type t =
    { mutable total_loss : float
    ; mutable samples : int
    }

  let create () = { total_loss = 0.; samples = 0 }

  let avg_and_reset t =
    let avg = t.total_loss /. Float.of_int t.samples in
    t.total_loss <- 0.;
    t.samples <- 0;
    avg

  let update t loss =
    t.total_loss <- t.total_loss +. loss;
    t.samples <- t.samples + 1
end

let () =
  let dataset =
    Dataset.create ~input_lang:"eng" ~output_lang:"fra" ~max_length |> Dataset.reverse
  in
  let ilang = Dataset.input_lang dataset in
  let olang = Dataset.output_lang dataset in
  Stdio.printf "Input:  %s %d words.\n%!" (Lang.name ilang) (Lang.length ilang);
  Stdio.printf "Output: %s %d words.\n%!" (Lang.name olang) (Lang.length olang);
  let device = Device.cuda_if_available () in
  let vs = Var_store.create ~name:"seq2seq" ~device () in
  let encoder = Encoder.create vs ~input_size:(Lang.length ilang) ~hidden_size in
  let decoder = Decoder.create vs ~output_size:(Lang.length olang) ~hidden_size in
  let optimizer = Optimizer.sgd vs ~learning_rate:0.01 in
  let pairs = Dataset.pairs dataset in
  let loss_stats = Loss_stats.create () in
  let decoder_start = Tensor.of_int1 [| Lang.sos_token olang |] in
  let decoder_eos = Lang.eos_token olang in
  for iter = 1 to 75_000 do
    let input_, target = pairs.(Random.int (Array.length pairs)) in
    let loss =
      train_loss ~input_ ~target ~encoder ~decoder ~decoder_start ~decoder_eos
    in
    Optimizer.backward_step optimizer ~loss;
    let loss = Tensor.to_float0_exn loss /. Float.of_int (List.length target) in
    Loss_stats.update loss_stats loss;
    if iter % 1_000 = 0
    then Stdio.printf "%d %f\n%!" iter (Loss_stats.avg_and_reset loss_stats)
  done
