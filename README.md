# MyInterpreter

Live multilingual captions and translation for macOS. Speak into the selected microphone to see the original transcript on the left and a translation on the right. Apple SpeechAnalyzer streams microphone captions. Current speech shows a single updating preview. Only finalized phrases are added to Conversation history. Stopping and starting keeps earlier rows. Translation prefers Apple Intelligence models when available.

## Run

1. Open `MyInterpreter.xcodeproj` in Xcode with the macOS 27 SDK or newer.
2. Select My Mac and press ⌘R. The app requires macOS 27 or later and on-device speech recognition for your chosen language.
3. Choose a **Spoken language** and a **Translate to** language. Korean is selected on first launch.
4. In **Input settings**, select your microphone and spoken language or regional variant (Australian English by default). Enable **Room microphone** for distant voices, or enter comma-separated names and terms for on-device Dictation vocabulary hints. Click **Start listening** and allow microphone access and the initial speech model download. If macOS offers a translation language download, complete it.
5. Click **Stop** to release the microphone. You can still select another language to translate the current conversation.

Audio comes from the input selected in System Settings → Sound. Meeting audio played through headphones requires a separately configured audio input. Recognition and translation use Apple’s on-device frameworks. The app keeps conversation text in memory for the session until you choose **Save…** (⌘S) to write a UTF-8 text file or **Share** to send a snapshot using the macOS share menu. Both include original captions, translations, available speaker labels and a marked draft if speech is in progress. Audio is never saved by the app.

## Speaker labels

FluidAudio Sortformer processes the same microphone stream locally, independently of captioning. On first use the app downloads its Core ML model from Hugging Face. If the model is unavailable, transcription and translation continue. Clear single-speaker intervals get a numbered label on the existing live or history row. Short, overlapping or mixed-speaker phrases may remain unlabeled. Up to four voices can be tracked per listening session. Starting a new session resets voice numbering. No voice profiles are saved.

## 한국어 사용법

Xcode에서 프로젝트를 열고 ⌘R로 실행하세요. **Spoken language**에서 말하는 언어를, **Translate to**에서 번역할 언어를 고른 뒤 **Start listening**을 누르면 선택한 언어의 원문과 번역이 나란히 표시됩니다. 처음 사용할 때는 마이크 권한과 음성 인식 및 번역 모델 다운로드가 필요할 수 있습니다. **Stop**을 누르면 마이크 입력이 종료됩니다.

## License

MIT. See [LICENSE](LICENSE).
