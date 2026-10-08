# Smart Track Controller

ESP32 신호등과 이동식 장애물을 Bluetooth로 제어하는 Android Flutter 앱입니다.

## 구성

- `lib/main.dart`: 신호등·장애물 제어 화면 및 Bluetooth 통신
- `firmware/ObstacleController`: 장애물 ESP32 펌웨어와 상세 설정 안내
- `firmware/ObstacleSwitchDiagnostic`: 끝 스위치 진단 코드
- `plugins/flutter_bluetooth_serial`: Android 호환성을 수정한 Bluetooth Serial 플러그인 (원본 LICENSE 포함)
- `test/obstacle_control_test.dart`: 연결·수동 정지·AUTO·속도 제어 테스트

신호등 펌웨어 소스는 이 저장소에 포함되어 있지 않습니다.

## 앱 빌드 및 휴대폰 설치

Flutter 3.41.6 / Dart 3.11과 Android SDK가 필요합니다. Windows에서는 `C:\src\smart-track-controller` 같은 짧은 영문 경로에 내려받으세요.

```powershell
git clone https://github.com/vhfflxpr6356-creator/smart-track-controller.git
cd smart-track-controller
flutter doctor --android-licenses
flutter pub get
flutter devices
flutter run -d <휴대폰_ID>
```

휴대폰에서 개발자 옵션의 USB 디버깅을 켜고 PC 연결 허용을 선택합니다. 위 명령의 휴대폰_ID를 `flutter devices` 결과로 바꾸면 앱을 빌드하여 설치하고 실행합니다.

APK만 만들 때:

```powershell
flutter build apk --debug
```

결과: `build/app/outputs/flutter-apk/app-debug.apk`. 휴대폰으로 복사하여 설치하며 압축을 풀지 않습니다. 디버그 앱 이름은 **트랙 장치 제어 v2**입니다. 다른 PC의 서명 키로 빌드하면 기존 설치본 업데이트가 거절될 수 있습니다.

## 장애물 펌웨어

Arduino IDE에서 `firmware/ObstacleController/ObstacleController.ino`를 열고 ESP32 보드 패키지, **ESP32 Dev Module**, 연결된 USB 포트를 선택하여 업로드합니다. 업로드는 기존 펌웨어를 대체합니다.

- Bluetooth 이름: `ESP32_Obstacle_2`
- 모터 출력: GPIO16 / 17 / 18 / 19
- 보드·모터 쪽 스위치: GPIO27, 반대쪽: GPIO26 (LOW = 눌림)
- 시리얼 모니터: 115200 baud, 줄바꿈 전송
- 부팅 상태: STOP. 방향 설정 후 READY:1이어야 앱 이동 버튼이 활성화됩니다.

방향 확인은 상세 펌웨어 README를 따릅니다. 양쪽 스위치가 해제된 상태에서 `JOG+`를 보내 짧은 이동 방향을 확인합니다. 보드 쪽으로 움직이면 `MAP+LEFT`, 반대쪽이면 `MAP+RIGHT`를 보냅니다.

AUTO는 지정한 끝을 찾은 뒤 끝 ↔ 설정 거리 왕복을 반복합니다. 수동 버튼은 누르는 동안 이동하고 놓으면 정지합니다. 속도는 정지 상태에서 저속·중속·고속을 선택합니다.

### 중간 거리 조정

정지 후 시리얼에 `MIDDLE=700`을 입력합니다. 숫자가 커질수록 출발 끝에서 더 멀리 이동합니다 (12~2400 위상 스텝). 설정은 재부팅 후에도 유지됩니다. `STATUS`로 확인하세요.

코드 기본값은 `DEFAULT_MIDDLE_STEPS = 600`입니다. 기본값을 수정하여 업로드했다면 `MIDDLE=DEFAULT`로 기존 저장값을 지워야 새 기본값이 적용됩니다. 600은 측정된 트랙 중간이 아닌 초기 시험값입니다.

## 확인 범위

Flutter 정적 분석·위젯 테스트와 ESP32 펌웨어 컴파일을 확인했습니다. 실제 장치에서 스위치 입력과 짧은 이동 방향을 확인했으며, 최신 속도·중간 왕복 설정의 전체 구동 검증은 별도로 필요합니다. 소프트웨어 정지는 전원 차단형 비상정지가 아닙니다. 예상과 다른 구동이나 갈리는 소리가 나면 전원을 끄세요.

원본 전체 플래시 백업, 개인 PC 설정, 서명 키, APK와 빌드 결과는 저장소에 포함하지 않습니다.
