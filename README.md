# MyInterpreter

Live English captions and translation for macOS. Speak into the selected microphone to see the English transcript on the left and a translation on the right. Both update as speech recognition revises a phrase.

## Run

1. Open `MyInterpreter.xcodeproj` in Xcode with the macOS 15 SDK or newer.
2. Select My Mac and press ⌘R. The app requires macOS 15 or later and on-device US English speech recognition.
3. Choose a target language. Korean is selected on first launch.
4. Click **Start listening** and allow microphone and speech recognition access. If macOS offers a translation language download, complete it.
5. Click **Stop** to release the microphone. You can still select another language to translate the current conversation.

Audio comes from the input selected in System Settings → Sound. Meeting audio played through headphones requires a separately configured audio input. Recognition and translation use Apple’s on-device frameworks. The app keeps conversation text in memory for the session and writes no recordings or transcript files.

## 한국어 사용법

Xcode에서 프로젝트를 열고 ⌘R로 실행하세요. **Translate to**에서 언어를 고른 뒤 **Start listening**을 누르면 영어 원문과 번역이 나란히 표시됩니다. 처음 사용할 때는 마이크 및 음성 인식 권한과 번역 언어 다운로드가 필요할 수 있습니다. **Stop**을 누르면 마이크 입력이 종료됩니다.

## License

MIT. See [LICENSE](LICENSE).
