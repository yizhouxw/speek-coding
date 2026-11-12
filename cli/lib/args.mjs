export const HELP_TEXT = `speek <command> [options]

Get started:
  setup        Install Speek, local ASR, and the macOS background service
  status       Show installation, device, permission, and ASR health
  start        Start the local ASR background service
  stop         Stop the local ASR background service
  restart      Rebuild and restart the local ASR background service
  logs         Show recent local ASR logs
  trigger      Toggle native recording through SpeekCoding.app
  cancel       Cancel the active native recording session
  permissions  Request and report SpeekCoding macOS permissions

Manage:
  config       Update audio, transcription, and delivery preferences
  doctor       Print the full diagnostic report
  update       Reconcile installed files with this package version
  test-record  Record a short WAV using the configured microphone
  uninstall    Remove Speek and its background service

Advanced:
  install      Install only the recording and Karabiner workflow
  asr-install  Install the configured local transcription engine
  asr-server   Run the OpenAI-compatible ASR server in the foreground
  configure    Alias for config

Options:
  --yes                  Skip confirmation prompts where possible
  --trigger-mode <mode>  keyboard | keyboard+dji
  --sound on|off         Enable or disable notification sounds
  --preconfirm-sound <n> Completion sound name, or off
  --ready-overlay on|off Show or hide the recording HUD
  --asr-url <url>        OpenAI-compatible transcription endpoint
  --asr-model <model>    ASR model name or whisper.cpp model path
  --asr-api-key-env <n>  Environment variable containing an API key
  --asr-language <lang>  auto or a fixed language code such as zh/en
  --asr-prompt <text>    Optional transcription vocabulary hint
  --transcript-cleanup <on|off>
                         Clean fillers, broken phrases, and coding terms (default: on)
  --fake-transcript <t>  Bypass ASR with a fixed transcript
  --asr-backend <name>   qwen-mlx | faster-whisper | whisper-cpp
  --asr-host <host>      Local ASR loopback bind host
  --asr-port <port>      Local ASR bind port
  --asr-device <device>  faster-whisper device, e.g. cpu
  --asr-compute-type <t> faster-whisper compute type, e.g. int8
  --asr-cpu-threads <n>  CPU thread count; 0 lets the backend decide
  --asr-beam-size <n>    Beam search width
  --asr-best-of <n>      Candidate count for whisper.cpp
  --whisper-cpp-bin <p>  Path to whisper-cli
  --whisper-cpp-timeout <sec>
                         Per-request whisper.cpp timeout
  --no-vad-filter        Disable faster-whisper voice detection
  --input-device <name>  Audio input device name fragment
  --input-device-index <index>
                         Fixed macOS audio device index
  --delivery-mode <mode> paste_and_send | paste_only | clipboard_only
  --skip-asr             Setup the input workflow without local ASR
  --no-start             Install local ASR without starting its service
  --follow               Follow logs until interrupted
  --lines <n>            Number of recent log lines (default: 80)
  --duration <sec>       Duration for test-record
  --wav <path>           Output WAV path for test-record
  --profile <name>       Target Karabiner profile name
  --clone-profile-from <name>
                         Clone an existing Karabiner profile
  --new-profile-name <n> Name for the cloned profile
  --json                 Print machine-readable JSON output
  --help                 Show this help text
  --version              Show CLI package version
`;

const VALUE_FLAGS = new Map([
	['--profile', 'profileName'],
	['--clone-profile-from', 'cloneProfileFrom'],
	['--new-profile-name', 'newProfileName'],
	['--sound', 'sound'],
	['--trigger-mode', 'triggerMode'],
	['--preconfirm-sound', 'preconfirmSoundName'],
	['--ready-overlay', 'readyOverlay'],
	// Kept as a hidden compatibility option for 0.1.x configs.
	['--review-window', 'reviewWindow'],
	['--asr-url', 'asrApiUrl'],
	['--asr-model', 'asrModel'],
	['--asr-api-key-env', 'asrApiKeyEnv'],
	['--asr-language', 'asrLanguage'],
	['--asr-prompt', 'asrPrompt'],
	['--transcript-cleanup', 'transcriptCleanup'],
	['--fake-transcript', 'fakeTranscript'],
	['--asr-backend', 'asrBackend'],
	['--asr-host', 'asrHost'],
	['--asr-port', 'asrPort'],
	['--asr-device', 'asrDevice'],
	['--asr-compute-type', 'asrComputeType'],
	['--asr-cpu-threads', 'asrCpuThreads'],
	['--asr-beam-size', 'asrBeamSize'],
	['--asr-best-of', 'asrBestOf'],
	['--whisper-cpp-bin', 'whisperCppBin'],
	['--whisper-cpp-timeout', 'whisperCppTimeout'],
	['--input-device', 'audioInputDeviceName'],
	['--input-device-index', 'audioInputDeviceIndex'],
	['--delivery-mode', 'deliveryMode'],
	['--lines', 'lines'],
	['--duration', 'duration'],
	['--wav', 'wavPath'],
]);

const BOOLEAN_FLAGS = new Map([
	['--yes', 'yes'],
	['--json', 'json'],
	['--help', 'help'],
	['--version', 'version'],
	['--no-vad-filter', 'noVadFilter'],
	['--skip-asr', 'skipAsr'],
	['--no-start', 'noStart'],
	['--follow', 'follow'],
]);

export function parseArgs(argv) {
	const args = [...argv];
	let command = 'help';
	if (args[0] && !args[0].startsWith('-')) {
		command = args.shift();
	}

	const flags = {};
	for (let index = 0; index < args.length; index += 1) {
		const arg = args[index];
		if (BOOLEAN_FLAGS.has(arg)) {
			flags[BOOLEAN_FLAGS.get(arg)] = true;
			continue;
		}
		if (VALUE_FLAGS.has(arg)) {
			const value = args[++index];
			if (value == null || value.startsWith('--')) {
				throw new Error(`Missing value for ${arg}`);
			}
			flags[VALUE_FLAGS.get(arg)] = value;
			continue;
		}
		throw new Error(`Unknown option: ${arg}`);
	}

	return { command, flags };
}
