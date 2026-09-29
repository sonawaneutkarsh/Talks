# Talks

> Distraction-free meeting capture for Apple Watch and iPhone with on-device intelligence and direct Notion synchronization.

---

## 1. Product Overview

**Talks** is an open-source, private-by-design meeting recording and synthesis system designed specifically for professors, researchers, and engineers. It captures meetings directly from your Apple Watch, safely transfers the audio to your iPhone over background channels, transcribes and structures the meeting using Apple's on-device foundation models, and creates an organized, beautifully formatted summary in your Notion workspace.

- **No Cloud AI Processing**: Audio and transcripts never touch third-party AI or speech servers. Transcription and synthesis execute locally on your iPhone using Apple Silicon hardware acceleration, before finalized notes are uploaded directly to your own Notion workspace.
- **No Recurring Subscription or API Costs**: No paid API keys for speech-to-text or large language models. Direct integration with the standard Notion API.
- **Distraction-Free**: Includes an academic "Screen Off" mode that blanks the watch face during research meetings while maintaining continuous recording.

---

## 2. System Architecture

```
┌─────────────────┐
│   Apple Watch   │
│  (TalksWatch)   │
└────────┬────────┘
         │
         │ 1. Record audio (AVAudioSession + WKExtendedRuntimeSession)
         │ 2. Distraction-free Screen Off capture
         │ 3. On Stop: Durable background file transfer (WCSession.transferFile)
         ▼
┌─────────────────┐
│     iPhone      │
│     (Talks)     │
└────────┬────────┘
         │
         │ 4. Receive audio & save atomically to disk
         │ 5. Send durable background ACK (WCSession.transferUserInfo)
         │ 6. Enqueue durable job in JobQueueManager
         │
         ├───▶ [7. On-Device Speech Transcription]
         │     • SpeechAnalyzer (#available(iOS 26.0, *)) with streaming watchdog
         │     • On-device SFSpeechRecognizer fallback on older supported iOS versions
         │
         ├───▶ [8. Apple Intelligence Structuring]
         │     • Foundation Models (System LLM)
         │     • Generates Title, Summary, Key Points, Decisions, Action Items
         │
         └───▶ [9. Direct Notion Upload]
               • Creates page under configured 'Talks' parent
               • Syncs structured blocks + collapsible raw transcript
               • Zero duplicate page protection
```

---

## 3. Key Features

- **One-Tap Apple Watch Recording**: Large, high-contrast record button with haptic feedback.
- **Screen Off Distraction-Free Mode**: Tap "Screen Off" during meetings to blank the watch display (`Color.black`) with a subtle, non-intrusive corner indicator. Safe wake-on-tap returns to controls without interrupting the recording.
- **Durable Background Transfer**: Transfers audio out-of-process via `WCSession.transferFile`. Audio on the Watch is only deleted after the iPhone sends a verified acknowledgement.
- **On-Device Speech Transcription**: Leverages Apple's Speech framework (`SpeechAnalyzer` under `#available(iOS 26.0, *)`, backed by an on-device `SFSpeechRecognizer` fallback on older supported iOS versions with cancellation-resistant watchdog isolation).
- **Apple Intelligence Structuring**: Extracts meeting titles, summaries, key takeaways, agreed decisions, and action items directly on device.
- **Direct Notion Sync**: Formats notes with native Notion callout, heading, bullet, and todo blocks. Retains full raw transcripts in an expandable toggle block.
- **Safe Local Swipe Deletion**: Swipe left on any completed or failed Talk to delete the local recording and metadata from iPhone. Active processing jobs are strictly protected, and external Notion pages are never deleted.
- **Resilient Offline Queue**: Jobs persist across app force-quits, reboots, and transient network interruptions. Failed uploads can be retried with one tap.

---

## Requirements

- **iPhone**: iOS 18.0 or later (minimum OS required to launch Talks, ingest background Watch audio transfers, and transcribe audio locally).
- **Apple Watch**: Any Apple Watch capable of running watchOS 11.0 or later.
- **Xcode**: Xcode 26.0 or later (Xcode 27.0 with Swift 6 and iOS 26+ SDK required to compile FoundationModels).
- **Supported Workflows by OS & Hardware**:
  - **iOS 26+ with Apple Intelligence** (iPhone 15 Pro, iPhone 16 series, or newer with Apple Intelligence enabled): Full automated end-to-end pipeline — Watch recording → background transfer → on-device `SpeechAnalyzer` transcription → on-device Foundation Models AI structuring → automatic Notion upload.
  - **iOS 18–25 or Apple Intelligence Unavailable**: Audio recording, background transfer, and local on-device transcription (via `SFSpeechRecognizer`) execute completely. The job queue then pauses at `.waitingForAI`; AI formatting and automatic structured Notion completion wait until Apple Intelligence becomes available (or until the queue is processed on an Apple Intelligence-capable device).
- **Notion Integration**: Free Notion Internal Integration Token and parent page ID with integration connection access (required for the Notion upload stage).

---

## 5. Setup & Installation

### Step 1: Clone the Repository
```bash
git clone https://github.com/sonawaneutkarsh/Talks.git
cd Talks
```

### Step 2: Configure Notion Integration
1. Go to [Notion Developers](https://www.notion.so/my-integrations) and create a **New integration**.
2. Give it a name (e.g. `Talks Assistant`) and copy the **Internal Integration Token**.
3. Open Notion in your browser, create or navigate to a page where you want meeting notes stored (e.g., `Research Notes` or `Meetings`).
4. Click the `...` menu in the upper-right corner of the parent page, select **Connections**, and connect your integration.
5. Copy the parent page link or page ID (the 32-character hexadecimal string in the page URL).

### Step 3: Build & Deploy via Xcode
1. Open `Talks.xcodeproj` in Xcode.
2. Select the `Talks` scheme and choose your physical iPhone as the run destination.
3. Configure your Apple Developer signing certificate under **Signing & Capabilities** for both `Talks` and `TalksWatch`.
4. Press **Cmd + R** to install and run Talks on your iPhone.
5. In the iPhone Talks app, open **Settings (gear icon)**:
   - Paste your Notion Integration Token into **Notion Integration Token**.
   - Paste your Parent Page URL or ID into **Parent Notion Page**.
   - Tap **Save Credentials to Keychain**.
   - Tap **Test Connection & Sync 'Talks' Page** to verify setup.
6. Switch schemes to `TalksWatch`, select your physical Apple Watch, and build & run.

### Using Talks on Your Own Apple Developer Account
When building Talks for personal devices:
1. **Choose Signing Team**: In Xcode, open `Talks.xcodeproj`. Under **Signing & Capabilities**, select your personal or organization Apple Developer Team for both the `Talks` (iOS) and `TalksWatch` (watchOS) targets.
2. **Unique Bundle Identifiers**: If the default bundle identifiers (`com.personal.talks` and `com.personal.talks.watchkitapp`) conflict with existing App IDs on your developer account, change them to your own unique prefix (e.g. `com.yourname.talks` and `com.yourname.talks.watchkitapp`). Ensure you preserve the Watch companion relationship: the Watch app's bundle ID must be prefixed with the iOS app's bundle ID (e.g., `<iOS-Bundle-ID>.watchkitapp`). You can also configure this prefix in `project.yml` under `bundleIdPrefix` and run `xcodegen generate`.

---

## 6. Physical Device Troubleshooting Guide

### WatchConnectivity Pairing & File Delivery
- **Watch App Installed check**: Ensure `TalksWatch.app` is embedded inside `Talks.app` (configured automatically in `project.yml`).
- **Transfer Timing**: `WCSession.transferFile` runs out-of-process via Apple's `wcd` daemon. Audio transfers in the background within 10–30 seconds after tapping Stop, depending on Bluetooth/Wi-Fi signal.
- **Durable Local Retention**: Recordings remain stored locally in `Documents/WatchRecordings/` on Apple Watch until the phone sends a verified ACK (`transferUserInfo`). If you walk out of range before transfer finishes, the transfer resumes automatically once back in range.

### Speech Model Assets
- Speech recognition models download once over Wi-Fi when first required by iOS. Check **Settings → Processing** to confirm transcription readiness.
- A built-in watchdog prevents speech analyzer hangs: if processing exceeds timeout boundaries, Talks automatically falls back to secondary on-device recognition engines without losing meeting audio.

### Notion Connection
- If connection fails, confirm your Notion integration is added to the parent page via **Page Menu (...) → Add connections**.
- Notion tokens are stored securely in the iOS Keychain and are never logged or exported.

---

## 7. Architecture & Design Decisions

### Why On-Device AI Processing?
- **Academic & Research Confidentiality**: Meeting discussions with collaborators, students, and industry partners often involve unpublished data, intellectual property, or confidential disclosures. Keeping audio transcription and AI structuring entirely local prevents exposing sensitive meeting discussions to third-party AI cloud services.
- **Zero Ongoing AI Costs**: Commercial LLM and STT APIs charge recurring fees per minute and per token. By running speech recognition and note structuring locally on Apple Silicon, Talks requires no third-party AI subscription or per-meeting API costs.

### Why Background Transfers vs. Live Streaming?
- Live streaming audio over Bluetooth during a 90-minute lecture drains watch battery and is prone to packet loss if you step away from your phone.
- Recording locally to high-efficiency AAC (`.m4a`) and performing background file transfers over `wcd` significantly reduces dropped audio segments from wireless dropouts and preserves battery efficiency.

### Crash & Force-Quit Resilience
- State transitions are recorded in a persistent, atomic JSON job queue (`Documents/job_queue.json`).
- If iOS terminates the app in the background, the queue resumes uncompleted jobs upon the next launch or background processing trigger.
- Duplicate prevention hashes each recording ID and checks Notion for existing pages before creating new entries.

---

## 8. Privacy & Recording Consent

- **Local Processing**: Audio recordings and transcripts remain entirely on your personal devices and are never transmitted to third-party AI or speech servers. The only external network communication is direct synchronization to your private Notion workspace via your configured integration credentials.
- **Recording Consent**: Please ensure you comply with all applicable local, state, and institutional recording consent laws and regulations before recording lectures, advising sessions, or meetings with collaborators.

---

## 9. License

MIT License. See [LICENSE](LICENSE) for details.

