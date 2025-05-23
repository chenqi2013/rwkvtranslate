// ignore_for_file: prefer_interpolation_to_compose_strings

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rwkvtranslate/from_rwkv.dart';
import 'package:rwkvtranslate/rwkv_mobile_ffi.dart';
import 'package:rwkvtranslate/to_rwkv.dart';
import 'package:rwkvtranslate/types.dart';

typedef _FromFrontend = ToRWKV;

// TODO: Use it, depends on "options.sendPort"
typedef _ToFrontend = FromRWKV;

const _codec = Utf8Codec(allowMalformed: true);

class RWKVMobile {
  Isolate? _isolate;

  // TODO: 对 Frontend 隐藏 sendPort
  Future<void> runIsolate(StartOptions options) async {
    if (_isolate != null) throw Exception('😡 Isolate already running');
    _isolate = await Isolate.spawn(_isolateMain, options);
  }

  static ffi.DynamicLibrary _getDynamicLibrary() {
    if (Platform.isAndroid) return ffi.DynamicLibrary.open('librwkv_mobile.so');
    if (Platform.isIOS) return ffi.DynamicLibrary.process();
    if (Platform.isMacOS)
      return ffi.DynamicLibrary.open('librwkv_mobile.dylib');
    if (Platform.isWindows)
      return ffi.DynamicLibrary.open('librwkv_mobile.dll');
    if (Platform.isLinux) {
      final abi = ffi.Abi.current();
      if (abi == ffi.Abi.linuxX64)
        return ffi.DynamicLibrary.open('librwkv_mobile-linux-x86_64.so');
      if (abi == ffi.Abi.linuxArm64)
        return ffi.DynamicLibrary.open('librwkv_mobile-linux-aarch64.so');
      throw Exception('😡 Unsupported ABI: ${abi.toString()}');
    }
    throw Exception('😡 Unsupported platform');
  }

  static String getAvailableBackendNames() {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    const backendNamesLength = 64; // should be enough
    ffi.Pointer<ffi.Char> responseBuffer =
        calloc.allocate<ffi.Char>(backendNamesLength);
    rwkvMobile.rwkvmobile_runtime_get_available_backend_names(
        responseBuffer, backendNamesLength);
    final response = responseBuffer.cast<Utf8>().toDartString();
    return response;
  }

  static String getPlatformName() {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    final platformName = rwkvMobile.rwkvmobile_get_platform_name();
    if (kDebugMode)
      print("💬 platformName: ${platformName.cast<Utf8>().toDartString()}");
    return platformName.cast<Utf8>().toDartString();
  }

  static String getSocName() {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    final socName = rwkvMobile.rwkvmobile_get_soc_name();
    if (kDebugMode) print("💬 socName: ${socName.cast<Utf8>().toDartString()}");
    return socName.cast<Utf8>().toDartString();
  }

  static String getSocPartname() {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    final socPartname = rwkvMobile.rwkvmobile_get_soc_partname();
    return socPartname.cast<Utf8>().toDartString();
  }

  static String getSnapdragonHtpArch() {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    final snapdragonHtpArch = rwkvMobile.rwkvmobile_get_htp_arch();
    if (kDebugMode)
      print(
          "💬 snapdragonHtpArch: ${snapdragonHtpArch.cast<Utf8>().toDartString()}");
    return snapdragonHtpArch.cast<Utf8>().toDartString();
  }

  void _isolateMain(StartOptions options) async {
    final sendPort = options.sendPort;
    final rootIsolateToken = options.rootIsolateToken;
    final receivePort = ReceivePort();
    sendPort.send(receivePort.sendPort);

    BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

    // TODO: We can call this when the app is launched, rather than when the model is selected
    // TODO: We can load the runtime in the future. Only Apple cannot.
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());

    if (kDebugMode) rwkvMobile.rwkvmobile_set_loglevel(RWKV_LOG_LEVEL_DEBUG);

    // definitions
    int maxLength = 2000;
    int maxMessages = 1000;
    int generationStopToken =
        0; // Takes effect in 'generation' mode; not used in 'chat' mode
    int retVal = 0;
    int enableReasoning = 0;

    final inputsPtr = calloc.allocate<ffi.Pointer<ffi.Char>>(maxMessages);

    var modelPath = options.modelPath;
    var modelBackend = options.backend.asArgument;
    var tokenizerPath = options.tokenizerPath;

    rwkvmobile_runtime_t runtime;

    // runtime initializations
    if (modelBackend == 'qnn') {
      // TODO: better solution for this
      final tempDir = await getTemporaryDirectory();
      if (kDebugMode) print("💬 tempDir: ${tempDir.path}");
      rwkvMobile.rwkvmobile_runtime_add_adsp_library_path(
          (tempDir.path + '/assets/lib/').toNativeUtf8().cast<ffi.Char>());

      runtime = rwkvMobile.rwkvmobile_runtime_init_with_name_extra(
          modelBackend.toNativeUtf8().cast<ffi.Char>(),
          (tempDir.path + '/assets/lib/libQnnHtp.so')
              .toNativeUtf8()
              .cast<ffi.Void>());
    } else {
      runtime = rwkvMobile.rwkvmobile_runtime_init_with_name(
          modelBackend.toNativeUtf8().cast<ffi.Char>());
    }

    if (runtime.address == 0)
      throw Exception('😡 Failed to initialize runtime');

    retVal = rwkvMobile.rwkvmobile_runtime_load_tokenizer(
        runtime, tokenizerPath.toNativeUtf8().cast<ffi.Char>());
    if (retVal != 0)
      throw Exception(
          '😡 Failed to load tokenizer, tokenizer path: $tokenizerPath');

    retVal = rwkvMobile.rwkvmobile_runtime_load_model(
        runtime, modelPath.toNativeUtf8().cast<ffi.Char>());
    if (retVal != 0)
      throw Exception('😡 Failed to load model, model path: $modelPath');

    final tempDir = await getTemporaryDirectory();
    rwkvMobile.rwkvmobile_set_cache_dir(
        runtime, tempDir.path.toNativeUtf8().cast<ffi.Char>());

    // TODO: @WangCe 逐渐地迁移到 handler 方法中, 最好不要在该方法声明局部变量
    await for (final (_FromFrontend, dynamic) message in receivePort) {
      switch (message.$1) {
        // 🟥 setMaxLength
        case SetMaxLength req:
          final arg = message.$2 as int;
          if (arg > 0) maxLength = arg;

        // 🟥 clearStates
        case ClearStates req:
          rwkvMobile.rwkvmobile_runtime_clear_state(runtime);

        // 🟥 setGenerationStopToken
        case SetGenerationStopToken req:
          final arg = message.$2 as int;
          if (arg >= 0) generationStopToken = arg;

        // 🟥 setPrompt
        case SetPrompt req:
          final prompt = message.$2 as String;
          final promptPtr = prompt.toNativeUtf8().cast<ffi.Char>();
          retVal = rwkvMobile.rwkvmobile_runtime_set_prompt(runtime, promptPtr);
          if (retVal != 0)
            sendPort.send(
                Error('Failed to set prompt: return value: $retVal', req));

        // 🟥 getPrompt
        case GetPrompt req:
          final stringBuffer = calloc.allocate<ffi.Char>(maxLength);
          rwkvMobile.rwkvmobile_runtime_get_prompt(
              runtime, stringBuffer, maxLength);
          final prompt = stringBuffer.cast<Utf8>().toDartString();
          sendPort.send({'currentPrompt': prompt});
          calloc.free(stringBuffer);

        // 🟥 setSamplerParams
        case SetSamplerParams req:
          final args = message.$2 as Map<String, dynamic>;
          final samplerParams = ffi.Struct.create<sampler_params>();
          final penaltyParams = ffi.Struct.create<penalty_params>();
          samplerParams.temperature = args['temperature'] as double;
          samplerParams.top_k = args['top_k'] as int;
          samplerParams.top_p = args['top_p'] as double;
          penaltyParams.presence_penalty = args['presence_penalty'] as double;
          penaltyParams.frequency_penalty = args['frequency_penalty'] as double;
          penaltyParams.penalty_decay = args['penalty_decay'] as double;
          rwkvMobile.rwkvmobile_runtime_set_sampler_params(
              runtime, samplerParams);
          rwkvMobile.rwkvmobile_runtime_set_penalty_params(
              runtime, penaltyParams);

        // 🟥 getSamplerParams
        case GetSamplerParams req:
          final samplerParams =
              rwkvMobile.rwkvmobile_runtime_get_sampler_params(runtime);
          final penaltyParams =
              rwkvMobile.rwkvmobile_runtime_get_penalty_params(runtime);
          sendPort.send({
            'samplerParams': {
              'temperature': samplerParams.temperature,
              'top_k': samplerParams.top_k,
              'top_p': samplerParams.top_p,
              'presence_penalty': penaltyParams.presence_penalty,
              'frequency_penalty': penaltyParams.frequency_penalty,
              'penalty_decay': penaltyParams.penalty_decay,
            }
          });

        // 🟥 setEnableReasoning
        case SetEnableReasoning req:
          // TODO: 这里不应该使用这个变量, 因为无法保证值同步至 cpp 的内存
          enableReasoning = message.$2 as bool ? 1 : 0;

        // 🟥 getEnableReasoning
        case GetEnableReasoning req:
          bool enableReasoningBool = (enableReasoning != 0);
          sendPort.send({'enableReasoning': enableReasoningBool});

        // 🟥 getIsGenerating
        case GetIsGenerating req:
          bool isGeneratingBool =
              (rwkvMobile.rwkvmobile_runtime_is_generating(runtime) != 0);
          sendPort.send({'isGenerating': isGeneratingBool});

        // 🟥 setThinkingToken
        case SetThinkingToken req:
          final arg = message.$2 as String;
          final thinkingTokenPtr = arg.toNativeUtf8().cast<ffi.Char>();
          retVal = rwkvMobile.rwkvmobile_runtime_set_thinking_token(
              runtime, thinkingTokenPtr);
          if (retVal != 0)
            sendPort.send(Error('Failed to set thinking token', req));

        // 🟥 setEosToken
        case SetEosToken req:
          final arg = message.$2 as String;
          final eosTokenPtr = arg.toNativeUtf8().cast<ffi.Char>();
          retVal =
              rwkvMobile.rwkvmobile_runtime_set_eos_token(runtime, eosTokenPtr);
          if (retVal != 0) sendPort.send(Error('Failed to set eos token', req));

        // 🟥 setBosToken
        case SetBosToken req:
          final arg = message.$2 as String;
          final bosTokenPtr = arg.toNativeUtf8().cast<ffi.Char>();
          retVal =
              rwkvMobile.rwkvmobile_runtime_set_bos_token(runtime, bosTokenPtr);
          if (retVal != 0) sendPort.send(Error('Failed to set bos token', req));

        // 🟥 setTokenBanned
        case SetTokenBanned req:
          final arg = message.$2 as List<int>;
          final tokenBannedPtr = calloc.allocate<ffi.Int>(arg.length);
          for (var i = 0; i < arg.length; i++) {
            tokenBannedPtr[i] = arg[i];
          }
          retVal = rwkvMobile.rwkvmobile_runtime_set_token_banned(
              runtime, tokenBannedPtr, arg.length);
          calloc.free(tokenBannedPtr);
          if (retVal != 0)
            sendPort.send(Error('Failed to set token banned', req));

        // 🟥 setUserRole
        case SetUserRole req:
          final arg = message.$2 as String;
          final userRolePtr = arg.toNativeUtf8().cast<ffi.Char>();
          retVal =
              rwkvMobile.rwkvmobile_runtime_set_user_role(runtime, userRolePtr);
          if (retVal != 0) sendPort.send(Error('Failed to set user role', req));

        // 🟥 loadVisionEncoder
        case LoadVisionEncoder req:
          final arg = message.$2 as String;
          final encoderPathPtr = arg.toNativeUtf8().cast<ffi.Char>();
          retVal = rwkvMobile.rwkvmobile_runtime_load_vision_encoder(
              runtime, encoderPathPtr);
          if (retVal != 0)
            sendPort.send(Error('Failed to load vision encoder', req));

        // 🟥 releaseVisionEncoder
        case ReleaseVisionEncoder req:
          retVal =
              rwkvMobile.rwkvmobile_runtime_release_vision_encoder(runtime);
          if (retVal != 0)
            sendPort.send(Error('Failed to release vision encoder', req));

        // 🟥 setVisionPrompt
        case SetVisionPrompt req:
          final arg = message.$2 as String;
          final imagePathPtr = arg.toNativeUtf8().cast<ffi.Char>();
          retVal = rwkvMobile.rwkvmobile_runtime_set_image_prompt(
              runtime, imagePathPtr);
          if (retVal != 0)
            sendPort.send(Error('Failed to set image prompt', req));

        // 🟥 loadWhisperEncoder
        case LoadWhisperEncoder req:
          final arg = message.$2 as String;
          final encoderPathPtr = arg.toNativeUtf8().cast<ffi.Char>();
          retVal = rwkvMobile.rwkvmobile_runtime_load_whisper_encoder(
              runtime, encoderPathPtr);
          if (retVal != 0)
            sendPort.send(Error('Failed to load whisper encoder', req));

        // 🟥 releaseWhisperEncoder
        case ReleaseWhisperEncoder req:
          retVal =
              rwkvMobile.rwkvmobile_runtime_release_whisper_encoder(runtime);
          if (retVal != 0)
            sendPort.send(Error('Failed to release whisper encoder', req));

        // 🟥 setAudioPrompt
        case SetAudioPrompt req:
          final arg = message.$2 as String;
          final audioPathPtr = arg.toNativeUtf8().cast<ffi.Char>();
          retVal = rwkvMobile.rwkvmobile_runtime_set_audio_prompt(
              runtime, audioPathPtr);
          if (retVal != 0)
            sendPort.send(Error('Failed to set audio prompt', req));

        // 🟥 message
        case RunChatAsync req:
          final messages = message.$2 as List<String>;
          for (var i = 0; i < messages.length; i++) {
            inputsPtr[i] = messages[i].toNativeUtf8().cast<ffi.Char>();
          }
          final numInputs = messages.length;

          if (rwkvMobile.rwkvmobile_runtime_is_generating(runtime) != 0) {
            sendPort.send(Error('LLM is already generating', req));
          } else {
            sendPort.send({'generateStart': true});
            if (kDebugMode)
              print("💬 Starting LLM generation thread (chat mode)");
            retVal = rwkvMobile.rwkvmobile_runtime_eval_chat_with_history_async(
                runtime,
                inputsPtr,
                numInputs,
                maxLength,
                ffi.nullptr,
                enableReasoning);
            if (kDebugMode)
              print("💬 Started LLM generation thread (chat mode)");
            if (retVal != 0)
              sendPort.send({
                'generateStop': true,
                'error': 'Failed to start generation thread: retVal: $retVal'
              });
          }

        // 🟥 generateAsync
        case GenerateAsync req:
          final prompt = message.$2 as String;
          final promptPtr = prompt.toNativeUtf8().cast<ffi.Char>();

          if (rwkvMobile.rwkvmobile_runtime_is_generating(runtime) != 0) {
            sendPort.send(Error('LLM is already generating', req));
          } else {
            sendPort.send({'generateStart': true});
            if (kDebugMode)
              print(
                  "🔥 Starting LLM generation thread (gen mode), maxlength = $maxLength");
            retVal = rwkvMobile.rwkvmobile_runtime_gen_completion_async(runtime,
                promptPtr, maxLength, generationStopToken, ffi.nullptr);
            if (kDebugMode)
              print("🔥 Started LLM generation thread (gen mode)");
            if (retVal != 0)
              sendPort.send({
                'generateStop': true,
                'error': 'Failed to start generation'
              });
          }

        // 🟥 generate
        case Generate req:
          final prompt = message.$2 as String;
          final promptPtr = prompt.toNativeUtf8().cast<ffi.Char>();
          String responseStr = prompt;

          callbackFunction(ffi.Pointer<ffi.Char> stream, int idx) {
            final prefillSpeed =
                rwkvMobile.rwkvmobile_runtime_get_avg_prefill_speed(runtime);
            final decodeSpeed =
                rwkvMobile.rwkvmobile_runtime_get_avg_decode_speed(runtime);
            responseStr += stream.cast<Utf8>().toDartString();
            sendPort.send({
              'streamResponse': stream.cast<Utf8>().toDartString(),
              'streamResponseToken': idx,
              'prefillSpeed': prefillSpeed,
              'decodeSpeed': decodeSpeed
            });
          }

          final nativeCallable = ffi.NativeCallable<
              ffi.Void Function(ffi.Pointer<ffi.Char>,
                  ffi.Int)>.isolateLocal(callbackFunction);
          sendPort.send({'generateStart': true});
          if (kDebugMode)
            print("🔥 Start to call LLM (gen mode), maxlength = $maxLength");
          retVal = rwkvMobile.rwkvmobile_runtime_gen_completion(
              runtime,
              promptPtr,
              maxLength,
              generationStopToken,
              nativeCallable.nativeFunction);
          if (kDebugMode) print("🔥 Call LLM done (gen mode)");
          if (retVal != 0)
            sendPort.send(
                {'generateStop': true, 'error': 'Failed to start generation'});

          sendPort.send({'response': responseStr});
          sendPort.send({'generateStop': true});

        // 🟥 releaseModel
        case ReleaseModel req:
          if (kDebugMode) print("💬 Releasing model");
          rwkvMobile.rwkvmobile_runtime_release(runtime);
          runtime = ffi.nullptr;

        // 🟥 initRuntime
        case InitRuntime req:
          final args = message.$2 as Map<String, dynamic>;
          modelPath = args['modelPath'] as String;
          modelBackend = args['backend'].asArgument;
          tokenizerPath = args['tokenizerPath'] as String;
          if (runtime.address != 0)
            rwkvMobile.rwkvmobile_runtime_release(runtime);

          if (modelBackend == 'qnn') {
            // TODO: better solution for this
            final tempDir = await getTemporaryDirectory();
            rwkvMobile.rwkvmobile_runtime_add_adsp_library_path(
                (tempDir.path + '/assets/lib/')
                    .toNativeUtf8()
                    .cast<ffi.Char>());

            runtime = rwkvMobile.rwkvmobile_runtime_init_with_name_extra(
                modelBackend.toNativeUtf8().cast<ffi.Char>(),
                (tempDir.path + '/assets/lib/libQnnHtp.so')
                    .toNativeUtf8()
                    .cast<ffi.Void>());
          } else {
            runtime = rwkvMobile.rwkvmobile_runtime_init_with_name(
                modelBackend.toNativeUtf8().cast<ffi.Char>());
          }
          if (runtime.address == 0) {
            sendPort.send({
              'initRuntimeDone': false,
              'error': 'Failed to initialize runtime'
            });
          } else {
            retVal = rwkvMobile.rwkvmobile_runtime_load_tokenizer(
                runtime, tokenizerPath.toNativeUtf8().cast<ffi.Char>());
            if (retVal != 0) {
              sendPort.send({
                'initRuntimeDone': false,
                'error':
                    'Failed to load tokenizer, tokenizer path: $tokenizerPath'
              });
            } else {
              retVal = rwkvMobile.rwkvmobile_runtime_load_model(
                  runtime, modelPath.toNativeUtf8().cast<ffi.Char>());
              if (retVal != 0) {
                sendPort.send({
                  'initRuntimeDone': false,
                  'error': 'Failed to load model, model path: $modelPath'
                });
              } else {
                sendPort.send({'initRuntimeDone': true});
              }
            }
          }

        // 🟥 stop
        case Stop req:
          bool generating =
              rwkvMobile.rwkvmobile_runtime_is_generating(runtime) == 1;
          while (generating) {
            rwkvMobile.rwkvmobile_runtime_stop_generation(runtime);
            if (kDebugMode) print("💬 Waiting for generation to stop...");
            await Future.delayed(const Duration(milliseconds: 5));
            generating =
                rwkvMobile.rwkvmobile_runtime_is_generating(runtime) == 1;
            if (!generating) sendPort.send({'generateStop': true});
          }

        // 🟥 getResponseBufferContent
        case GetResponseBufferContent req:
          final responseBufferContent = rwkvMobile
              .rwkvmobile_runtime_get_response_buffer_content(runtime);
          int length = responseBufferContent.length;
          final Uint8List byteList = responseBufferContent.content
              .cast<ffi.Uint8>()
              .asTypedList(length);
          final String str = _codec.decode(byteList);
          sendPort.send({'responseBufferContent': str});

        // 🟥 getPrefillAndDecodeSpeed
        case GetPrefillAndDecodeSpeed req:
          final prefillSpeed =
              rwkvMobile.rwkvmobile_runtime_get_avg_prefill_speed(runtime);
          final decodeSpeed =
              rwkvMobile.rwkvmobile_runtime_get_avg_decode_speed(runtime);
          sendPort
              .send({'prefillSpeed': prefillSpeed, 'decodeSpeed': decodeSpeed});

        // 🟥 getResponseBufferIds
        case GetResponseBufferIds req:
          final responseBufferIds =
              rwkvMobile.rwkvmobile_runtime_get_response_buffer_ids(runtime);
          final responseBufferIdsList =
              responseBufferIds.ids.asTypedList(responseBufferIds.len).toList();
          rwkvMobile.rwkvmobile_runtime_free_token_ids(responseBufferIds);
          sendPort.send({'responseBufferIds': responseBufferIdsList});

        // 🟥 loadTTSModels
        case LoadTTSModels req:
          final args = message.$2 as Map<String, dynamic>;
          final campPlusPath = args['campPlusPath'] as String;
          final flowDecoderEstimatorPath =
              args['flowDecoderEstimatorPath'] as String;
          final flowEncoderPath = args['flowEncoderPath'] as String;
          final hiftGeneratorPath = args['hiftGeneratorPath'] as String;
          final speechTokenizerPath = args['speechTokenizerPath'] as String;
          final ttsTokenizerPath = args['ttsTokenizerPath'] as String;
          retVal = rwkvMobile.rwkvmobile_runtime_cosyvoice_load_models(
              runtime,
              speechTokenizerPath.toNativeUtf8().cast<ffi.Char>(),
              campPlusPath.toNativeUtf8().cast<ffi.Char>(),
              flowEncoderPath.toNativeUtf8().cast<ffi.Char>(),
              flowDecoderEstimatorPath.toNativeUtf8().cast<ffi.Char>(),
              hiftGeneratorPath.toNativeUtf8().cast<ffi.Char>(),
              ttsTokenizerPath.toNativeUtf8().cast<ffi.Char>());
          if (retVal != 0)
            sendPort.send(Error('Failed to load TTS models', req));
          rwkvMobile.rwkvmobile_runtime_cosyvoice_set_cfm_steps(runtime, 5);

        // 🟥 loadTTSTextNormalizer
        case LoadTTSTextNormalizer req:
          final args = message.$2 as Map<String, dynamic>;
          final fstPath = args['fstPath'] as String;
          retVal = rwkvMobile.rwkvmobile_runtime_tts_register_text_normalizer(
              runtime, fstPath.toNativeUtf8().cast<ffi.Char>());
          if (retVal != 0)
            sendPort.send(
                Error('Failed to load TTS Text Normalizer file $fstPath', req));

        // 🟥 releaseTTSModels
        case ReleaseTTSModels req:
          retVal =
              rwkvMobile.rwkvmobile_runtime_cosyvoice_release_models(runtime);
          if (retVal != 0)
            sendPort.send(Error('Failed to release TTS models', req));

        // 🟥 runTTS
        case RunTTS req:
          final args = message.$2 as Map<String, dynamic>;
          final ttsText = args['ttsText'] as String;
          final instructionText = args['instructionText'] as String;
          final promptSpeechText = args['promptSpeechText'] as String;
          final promptWavPath = args['promptWavPath'] as String;
          final outputWavPath = args['outputWavPath'] as String;
          retVal = rwkvMobile.rwkvmobile_runtime_run_tts(
            runtime,
            ttsText.toNativeUtf8().cast<ffi.Char>(),
            instructionText.toNativeUtf8().cast<ffi.Char>(),
            promptSpeechText.toNativeUtf8().cast<ffi.Char>(),
            promptWavPath.toNativeUtf8().cast<ffi.Char>(),
            outputWavPath.toNativeUtf8().cast<ffi.Char>(),
          );
          if (retVal != 0) {
            sendPort.send(Error('Failed to run TTS', req));
          } else {
            sendPort.send({'ttsDone': true, 'outputWavPath': outputWavPath});
          }

        // 🟥 runTTSAsync
        case RunTTSAsync req:
          final ttsText = req.ttsText;
          final instructionText = req.instructionText;
          final promptSpeechText = req.promptSpeechText;
          final promptWavPath = req.promptWavPath;
          final outputWavPath = req.outputWavPath;
          retVal = rwkvMobile.rwkvmobile_runtime_run_tts_async(
            runtime,
            ttsText.toNativeUtf8().cast<ffi.Char>(),
            instructionText.toNativeUtf8().cast<ffi.Char>(),
            promptSpeechText.toNativeUtf8().cast<ffi.Char>(),
            promptWavPath.toNativeUtf8().cast<ffi.Char>(),
            outputWavPath.toNativeUtf8().cast<ffi.Char>(),
          );
          if (retVal != 0) {
            sendPort.send(Error('Failed to run TTS', req));
            break;
          } else {
            sendPort.send(TTSGenerationStart(start: true, toRWKV: req));
          }

        // 🟥 getTTSGenerationProgress
        case GetTTSGenerationProgress req:
          bool isGeneratingBool =
              (rwkvMobile.rwkvmobile_runtime_is_generating(runtime) != 0);
          if (!isGeneratingBool) {
            sendPort.send(TTSGenerationProgress(
                overallProgress: -1, perWavProgress: -1, toRWKV: req));
            break;
          }
          final ttsOutputFiles = rwkvMobile
              .rwkvmobile_runtime_tts_get_current_output_files(runtime);
          final outputFiles = ttsOutputFiles.cast<Utf8>().toDartString();
          final fileList = outputFiles
              .split(',')
              .map((f) => f.replaceAll('"', '').trim())
              .toList();
          final numCurrentGeneratedWavs = fileList.length;
          final numTotalWavs = rwkvMobile
              .rwkvmobile_runtime_tts_get_num_total_output_wavs(runtime);
          final ttsPerWavProgress = rwkvMobile
              .rwkvmobile_runtime_tts_get_generation_progress(runtime);
          final ttsOverallProgress =
              (numCurrentGeneratedWavs + ttsPerWavProgress) / numTotalWavs;
          // Range from 0.0 to 1.0
          sendPort.send(TTSGenerationProgress(
              overallProgress: ttsOverallProgress,
              perWavProgress: ttsPerWavProgress,
              toRWKV: req));

        // 🟥 getTTSOutputFileList
        case GetTTSOutputFileList req:
          final ttsOutputFiles = rwkvMobile
              .rwkvmobile_runtime_tts_get_current_output_files(runtime);
          final outputFiles = ttsOutputFiles.cast<Utf8>().toDartString();
          final fileList = outputFiles
              .split(',')
              .map((f) => f.replaceAll('"', '').trim())
              .toList();
          sendPort.send(TTSOutputFileList(outputFileList: fileList));

        // 🟥 setTTSCFMSteps
        case SetTTSCFMSteps req:
          final cfmSteps = req.cfmSteps;
          retVal = rwkvMobile.rwkvmobile_runtime_cosyvoice_set_cfm_steps(
              runtime, cfmSteps);
          if (retVal != 0)
            sendPort.send(Error('Failed to set TTS CFM steps', req));

        // 🟥 dumpLog
        case DumpLog req:
          final log = rwkvMobile.rwkvmobile_dump_log();
          sendPort.send({'runtimeLog': log.cast<Utf8>().toDartString()});
      }
    }
  }
}
