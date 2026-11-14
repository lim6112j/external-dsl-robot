// robotdsl 음성 인식 헬퍼.
//
// 마이크에서 한 문장을 받아 stdout 에 한 줄로 출력한다.
//   exit 0  인식 성공
//   exit 1  무음 (아무 말도 인식되지 않음)
//   exit 2  권한 거부
//   exit 3  인식기 사용 불가
//
// --probe 모드는 권한 프롬프트 없이 인식기 가용성만 보고한다.
// 빌드: swiftc -O main.swift -o stt

import Speech
import AVFoundation

// 여러 문장을 받되, 최종 결과만 출력한다.
let locale = Locale(identifier: "ko-KR")

// --probe: 권한 요청 없이 가용성만 보고
if CommandLine.arguments.contains("--probe") {
    guard let r = SFSpeechRecognizer(locale: locale) else {
        print("available=false")
        exit(3)
    }
    print("available=\(r.isAvailable)")
    print("onDevice=\(r.supportsOnDeviceRecognition)")
    exit(0)
}

guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
    FileHandle.standardError.write("speech recognizer is unavailable for this locale\n".data(using: .utf8)!)
    exit(3)
}

// 온디바이스 인식을 선호한다 (네트워크 불필요). 미지원 로케일에서는 경고만.
if !recognizer.supportsOnDeviceRecognition {
    FileHandle.standardError.write("note: on-device recognition is unavailable; using server recognition\n".data(using: .utf8)!)
}

// 권한 확인. else 분기가 반드시 종료해야 하므로 guard 대신 플래그를 쓴다.
var authorized = (SFSpeechRecognizer.authorizationStatus() == .authorized)
if !authorized {
    let status = SFSpeechRecognizer.authorizationStatus()
    if status == .denied || status == .restricted {
        FileHandle.standardError.write("speech recognition permission denied\n".data(using: .utf8)!)
        exit(2)
    }
    // notDetermined: 요청
    let sem = DispatchSemaphore(value: 0)
    SFSpeechRecognizer.requestAuthorization { s in
        authorized = (s == .authorized)
        sem.signal()
    }
    sem.wait()
}
guard authorized else {
    FileHandle.standardError.write("speech recognition permission denied\n".data(using: .utf8)!)
    exit(2)
}

// 오디오 엔진과 인식 요청
let audioEngine = AVAudioEngine()
let request = SFSpeechAudioBufferRecognitionRequest()
request.shouldReportPartialResults = true
if recognizer.supportsOnDeviceRecognition {
    request.requiresOnDeviceRecognition = true
}

var finalText: String?
var recognitionError: Error?

let doneSem = DispatchSemaphore(value: 0)

let inputNode = audioEngine.inputNode
let recordingFormat = inputNode.outputFormat(forBus: 0)
inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
    request.append(buffer)
}

let task = recognizer.recognitionTask(with: request) { result, error in
    if let error = error {
        recognitionError = error
        doneSem.signal()
        return
    }
    guard let result = result else { return }
    if result.isFinal {
        finalText = result.bestTranscription.formattedString
        doneSem.signal()
    }
}

audioEngine.prepare()
do {
    try audioEngine.start()
} catch {
    FileHandle.standardError.write("could not start the microphone: \(error)\n".data(using: .utf8)!)
    task.cancel()
    request.endAudio()
    exit(3)
}

// 최종 결과 또는 15초 제한
let waited = doneSem.wait(timeout: .now() + 15)
audioEngine.stop()
inputNode.removeTap(onBus: 0)
request.endAudio()
task.cancel()

if waited == .timedOut {
    FileHandle.standardError.write("no speech recognised within 15 seconds\n".data(using: .utf8)!)
    exit(1)
}

if let error = recognitionError {
    let nsError = error as NSError
    // 무음이면 조용히 종료 코드 1
    if nsError.domain == NSPOSIXErrorDomain || nsError.code == 1110 || nsError.code == 203 {
        FileHandle.standardError.write("no speech recognised\n".data(using: .utf8)!)
        exit(1)
    }
    FileHandle.standardError.write("recognition failed: \(error)\n".data(using: .utf8)!)
    exit(3)
}

guard let text = finalText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    FileHandle.standardError.write("no speech recognised\n".data(using: .utf8)!)
    exit(1)
}

// stdout 에 한 줄만 출력한다.
print(text)
