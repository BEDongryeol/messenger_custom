#!/usr/bin/ruby
# encoding: utf-8
# Dooray Skin Mac 주입기 ("cdp-port" 방식)
#
# 왜 필요한가
#   Dooray Mac 4.0.4 부터 Electron 보안 설정(fuse)이 바뀌어 기존 방식을 쓸 수 없다:
#     - RunAsNode 꺼짐            : Dooray 실행 파일을 Node 로 돌리는 방법(ELECTRON_RUN_AS_NODE) 불가
#     - EnableNodeCliInspectArguments 꺼짐 : --inspect 로 메인 프로세스에 붙는 방법 불가
#   그래서 Windows 와 같이 Chromium 의 원격 디버그 포트(--remote-debugging-port)로 "화면(렌더러)"에만 붙는다.
#   메인 프로세스에는 못 붙으므로 창 투명도·제목 표시줄 다크·앱 안 자동 설치(메인 프로세스 훅)는 쓸 수 없고,
#   화면 단위 기능(배경, 테마 색, 다크 모드, 잠금, 사이드바 버튼/패널)은 그대로 된다. 업데이트는 이 주입기가 처리한다.
#
# 동작
#   1) Dooray 를 디버그 포트를 연 상태로 (필요하면 종료 후) 실행한다.
#   2) 브라우저 CDP 연결 하나를 유지하며 Target.* 이벤트로 새 화면/주소 변경/닫힘을 받아 core.js 를 주입하고,
#      Page.addScriptToEvaluateOnNewDocument 로 시작 덮개(early.js)를 새 문서마다 먼저 실행한다.
#   3) 페이지가 Runtime.addBinding('__drbNotify') 로 알리면 바로, 아니면 2.5초마다 상태를 읽어 업데이트 요청을 처리한다.
#   4) Dooray 가 꺼져도 계속 살아 있다가(감시), Dooray 가 Skin 없이 막 시작되면(예: Dooray 자체 업데이트 직후 자동 재시작)
#      디버그 포트로 다시 실행한다. 시작한 지 90초가 지난 Dooray 는 건드리지 않는다.
#      끄기: 데이터 폴더(~/Library/Application Support/DooraySkin)에 keeper.off 파일을 만든다.
#   macOS 기본 Ruby(/usr/bin/ruby) 표준 라이브러리만 쓴다 (개발자 도구 설치 불필요).
#
# 사용: ruby cdp-injector.rb --app "/Applications/Dooray Messenger.app" --res <core.js 폴더> --data <데이터 폴더> --app-version 4.0.4
# 시험용 환경 변수: DRB_TEST=1 (실행/종료/프로세스 조회/알림을 하지 않음), DRB_PORT, DRB_ALIVE_FILE(없어지면 Dooray 종료로 간주)
require 'socket'
require 'json'
require 'digest/sha1'
require 'base64'
require 'net/http'
require 'securerandom'
require 'fileutils'
require 'open3'
require 'time'
require 'uri'
require 'tmpdir'

TEST = ENV['DRB_TEST'] == '1'
args = ARGV.each_slice(2).to_h
APP = args['--app'] || '/Applications/Dooray Messenger.app'
RES = args['--res'] || File.dirname(File.expand_path(__FILE__))
DATA = args['--data'] || File.join(Dir.home, 'Library', 'Application Support', 'DooraySkin')
APP_VERSION = args['--app-version'] || ''
FileUtils.mkdir_p(DATA)
LOG = File.join(DATA, 'launcher.log')

def log(msg)
  line = "[#{Time.now.utc.iso8601(3)}] #{msg}\n"
  File.open(LOG, 'a') { |f| f.write(line) } rescue nil
  $stdout.write(line) rescue nil
end

def notify(msg)
  return if TEST
  system('/usr/bin/osascript', '-e', "display notification #{msg.inspect} with title \"Dooray Skin\"", out: File::NULL, err: File::NULL)
end

def now_ms
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
end

DOORAY_RE = %r{\Ahttps://([a-z0-9-]+\.)*dooray\.com/}
UPDATE_URL_RE = %r{\Ahttps://github\.com/BEDongryeol/messenger_custom/releases/download/[^/]+/DooraySkin-mac\.zip\z}
CORE = File.read(File.join(RES, 'core.js'), encoding: 'UTF-8')
EARLY = (File.read(File.join(RES, 'early.js'), encoding: 'UTF-8') rescue nil)
ENV_JSON = JSON.generate(
  platform: 'mac', app: APP_VERSION, strategy: 'cdp-port',
  caps: { windowOpacity: false, darkTitleBar: false, autoUpdate: true }
)
INJECT_EXPR = "window.__DRB_HOST='desktop';window.__DRB_ENV=#{ENV_JSON};\n#{CORE}\n;'injected'"
# 화면 상태: core 주입 여부, 로딩 상태, 업데이트 요청, 하트비트(core 의 "호스트 응답 중" 판단용)
CHECK_EXPR = "JSON.stringify({core: !!window.__drbCore, rs: document.readyState, upd: window.__drbUpdateRequest||null, alive: (window.__drbWatcherAlive=Date.now(),1), v: (window.__drbSkin&&window.__drbSkin.version)||null})"

# ---------------------------------------------------------------- 최소 WebSocket 클라이언트
class WebSocketClient
  GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'.freeze

  def initialize(url)
    u = URI.parse(url)
    # Ruby 2.6 의 URI 는 ws:// 를 일반 URI 로 읽어 request_uri 가 없다 → 경로를 직접 만든다
    path = u.path.to_s.empty? ? '/' : u.path
    path += "?#{u.query}" if u.query
    @sock = TCPSocket.new(u.host, u.port)
    @sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    key = Base64.strict_encode64(SecureRandom.random_bytes(16))
    @sock.write("GET #{path} HTTP/1.1\r\nHost: #{u.host}:#{u.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    status = @sock.gets
    raise "WebSocket 연결 실패: #{status.inspect}" unless status && status.include?(' 101 ')
    accept = nil
    while (line = @sock.gets) && line != "\r\n"
      accept = line.split(':', 2)[1].to_s.strip if line =~ /\Asec-websocket-accept:/i
    end
    raise 'WebSocket 응답 검증 실패' unless accept == Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
    @buf = ''.b
    @msg = ''.b
  end

  def send_frame(opcode, payload)
    payload = payload.dup.force_encoding('BINARY')
    mask = SecureRandom.random_bytes(4)
    len = payload.bytesize
    head = [0x80 | opcode].pack('C')
    head << if len < 126 then [0x80 | len].pack('C')
            elsif len < 65_536 then [0x80 | 126, len].pack('Cn')
            else [0x80 | 127, len >> 32, len & 0xffffffff].pack('CNN')
            end
    m = mask.bytes
    masked = payload.bytes.each_with_index.map { |b, i| b ^ m[i & 3] }.pack('C*')
    @sock.write(head + mask + masked)
  end

  def send_text(str)
    send_frame(0x1, str)
  end

  # 완성된 메시지(문자열) 목록. timeout 초 안에 데이터가 없으면 빈 배열
  def read_messages(timeout)
    out = parse_frames
    return out unless out.empty?
    return out unless IO.select([@sock], nil, nil, timeout)
    chunk = @sock.read_nonblock(1 << 20, exception: false)
    raise 'WebSocket 닫힘' if chunk.nil?
    @buf << chunk if chunk.is_a?(String)
    parse_frames
  end

  def close
    @sock.close
  rescue StandardError
    nil
  end

  private

  def parse_frames
    out = []
    loop do
      break if @buf.bytesize < 2
      b0 = @buf.getbyte(0)
      b1 = @buf.getbyte(1)
      fin = (b0 & 0x80) != 0
      op = b0 & 0x0f
      masked = (b1 & 0x80) != 0
      len = b1 & 0x7f
      off = 2
      if len == 126
        break if @buf.bytesize < 4
        len = @buf.byteslice(2, 2).unpack1('n')
        off = 4
      elsif len == 127
        break if @buf.bytesize < 10
        hi, lo = @buf.byteslice(2, 8).unpack('NN')
        len = (hi << 32) | lo
        off = 10
      end
      off += 4 if masked
      break if @buf.bytesize < off + len
      payload = @buf.byteslice(off, len)
      @buf = @buf.byteslice(off + len, @buf.bytesize - off - len) || ''.b
      case op
      when 8 then raise 'WebSocket 닫힘'
      when 9 then send_frame(0xA, payload)
      when 0, 1
        @msg << payload
        if fin
          out << @msg.dup.force_encoding('UTF-8')
          @msg = ''.b
        end
      end
    end
    out
  end
end

# ---------------------------------------------------------------- Dooray 프로세스/포트
def port_file
  File.join(DATA, 'port.txt')
end

def debug_port
  return ENV['DRB_PORT'].to_i if ENV['DRB_PORT']
  File.write(port_file, (20_000 + rand(25_000)).to_s) unless File.exist?(port_file)
  File.read(port_file).strip.to_i
end

def dooray_pids
  return (File.exist?(ENV['DRB_ALIVE_FILE'].to_s) ? [1] : []) if TEST
  out, = Open3.capture2e('/usr/bin/pgrep', '-x', 'Dooray Messenger')
  out.split.map(&:to_i)
end

# 프로세스가 시작된 지 몇 초인지 (ps etime: [[dd-]hh:]mm:ss)
def age_seconds(pid)
  return ENV['DRB_TEST_AGE'].to_i if TEST && ENV['DRB_TEST_AGE']
  out, = Open3.capture2e('/bin/ps', '-o', 'etime=', '-p', pid.to_s)
  t = out.strip
  return 10**9 if t.empty?
  days = t.include?('-') ? t.split('-')[0].to_i : 0
  parts = t.split('-').last.split(':').map(&:to_i)
  parts.unshift(0) while parts.size < 3
  days * 86_400 + parts[0] * 3600 + parts[1] * 60 + parts[2]
end

def version_info(port)
  Net::HTTP.start('127.0.0.1', port, open_timeout: 1.5, read_timeout: 2) { |h| JSON.parse(h.get('/json/version').body) }
rescue StandardError
  nil
end

def quit_dooray
  return if TEST
  log '기존 Dooray 종료'
  system('/usr/bin/osascript', '-e', 'tell application id "com.dooray.messenger" to quit', out: File::NULL, err: File::NULL)
  40.times { break if dooray_pids.empty?; sleep 0.25 }
  dooray_pids.each { |p| Process.kill('TERM', p) rescue nil }
  20.times { break if dooray_pids.empty?; sleep 0.25 }
  dooray_pids.each { |p| Process.kill('KILL', p) rescue nil }
  sleep 0.5
end

def launch_dooray(port)
  if TEST
    log "(시험) Dooray 실행 생략 port=#{port}"
    return
  end
  system('/usr/bin/open', '-a', APP, '--args', "--remote-debugging-port=#{port}")
  log "Dooray 실행 (디버그 포트 #{port})"
end

def activate_dooray
  system('/usr/bin/open', '-a', APP) unless TEST
end

# Dooray 가 디버그 포트를 연 상태가 되도록 한다. 반환: 포트 정보(Hash) 또는 nil
def ensure_dooray_with_port(port)
  info = version_info(port)
  pids = dooray_pids
  if info && !pids.empty?
    log "이미 디버그 포트로 실행 중 (pid #{pids.first})"
    activate_dooray
    return info
  end
  quit_dooray unless pids.empty?
  launch_dooray(port)
  60.times do
    info = version_info(port)
    return info if info
    sleep 0.5
  end
  nil
end

# ---------------------------------------------------------------- 업데이트 (이 주입기가 처리)
def http_get_follow(url, limit = 6)
  raise '리다이렉트 초과' if limit.zero?
  u = URI.parse(url)
  Net::HTTP.start(u.host, u.port, use_ssl: u.scheme == 'https', open_timeout: 15, read_timeout: 60) do |h|
    r = h.get(u.request_uri, 'User-Agent' => 'dooray-skin')
    return r.body if r.is_a?(Net::HTTPSuccess)
    return http_get_follow(URI.join(url, r['location']).to_s, limit - 1) if r.is_a?(Net::HTTPRedirection)
    raise "다운로드 #{r.code}"
  end
end

# 반환: 실패 메시지(String) 또는 nil(성공)
def do_update(upd)
  url = upd['url'].to_s
  return '허용되지 않은 주소' unless url =~ UPDATE_URL_RE
  log "update start #{upd['version']} #{url}"
  dir = Dir.mktmpdir('dooray-skin-')
  zip = File.join(dir, 'DooraySkin-mac.zip')
  File.binwrite(zip, http_get_follow(url))
  _, st = Open3.capture2e('/usr/bin/ditto', '-x', '-k', zip, dir)
  return '압축 풀기 실패' unless st.success?
  app = File.join(dir, 'Dooray Skin.app')
  return 'zip 안에 Dooray Skin.app 이 없습니다' unless File.exist?(File.join(app, 'Contents', 'MacOS', 'DooraySkin'))
  system('/usr/bin/xattr', '-dr', 'com.apple.quarantine', app, err: File::NULL) unless TEST
  log "update downloaded #{File.size(zip)} bytes -> #{app}"
  if TEST
    log '(시험) 새 앱 실행 생략'
  else
    # 새 Dooray Skin.app 이 ~/Applications 에 자기 설치하고 Dooray 를 다시 시작한다 (브라우저가 아닌 이 프로세스가 받았으므로 Gatekeeper 경고 없음)
    pid = Process.spawn('/usr/bin/open', '-n', app, out: File::NULL, err: File::NULL)
    Process.detach(pid)
  end
  nil
rescue StandardError => e
  "업데이트 오류: #{e.message}"
end

# ---------------------------------------------------------------- 이벤트 루프
def run_event_loop(port, state)
  info = version_info(port)
  return :fallback unless info && info['webSocketDebuggerUrl']
  ws = WebSocketClient.new(info['webSocketDebuggerUrl'])
  log 'cdp connected (event mode)'
  seq = 0
  pend = {}
  targets = {} # targetId => { url, title, sid, attaching, due }
  sids = {}
  binding_ok = false
  next_alive = 0
  send_cmd = lambda do |method, params = {}, sid = nil, tag = nil|
    seq += 1
    m = { id: seq, method: method, params: params }
    m[:sessionId] = sid if sid
    pend[seq] = tag if tag
    ws.send_text(JSON.generate(m))
    seq
  end
  send_cmd.call('Target.setDiscoverTargets', { discover: true })
  loop do
    ws.read_messages(0.15).each do |txt|
      # 필요 없는 이벤트(Page.* 등)는 해석하지 않고 건너뛴다
      next if txt.start_with?('{"method":"') && !(txt.start_with?('{"method":"Target.') || txt.start_with?('{"method":"Runtime.bindingCalled"'))
      o = JSON.parse(txt) rescue next
      if o['method']
        case o['method']
        when 'Target.targetCreated', 'Target.targetInfoChanged'
          i = o['params']['targetInfo']
          next unless i['type'] == 'page'
          t = (targets[i['targetId']] ||= { url: '', title: '', sid: nil, attaching: false, due: 0 })
          if t[:url] != i['url']
            t[:url] = i['url'].to_s
            t[:due] = now_ms + 300
          end
          t[:title] = i['title'].to_s
          if !t[:sid] && !t[:attaching]
            t[:attaching] = true
            send_cmd.call('Target.attachToTarget', { targetId: i['targetId'], flatten: true }, nil, { k: :attach, tid: i['targetId'] })
          end
        when 'Target.targetDestroyed'
          t = targets.delete(o['params']['targetId'])
          sids.delete(t[:sid]) if t && t[:sid]
        when 'Target.detachedFromTarget'
          tid = sids.delete(o['params']['sessionId'])
          if tid && targets[tid]
            targets[tid][:sid] = nil
            targets[tid][:attaching] = false
          end
        when 'Runtime.bindingCalled'
          if o['params']['name'] == '__drbNotify' && sids[o['sessionId']]
            targets[sids[o['sessionId']]][:due] = 0
            unless binding_ok
              binding_ok = true
              log 'binding ok (instant updates)'
            end
          end
        end
        next
      end
      next unless o['id'] && pend.key?(o['id'])
      tag = pend.delete(o['id'])
      t = tag[:tid] ? targets[tag[:tid]] : nil
      case tag[:k]
      when :attach
        next unless t
        t[:attaching] = false
        sid = o.dig('result', 'sessionId')
        unless sid
          log "cdp attach failed #{tag[:tid]} #{o['error'].to_json}"
          next
        end
        t[:sid] = sid
        sids[sid] = tag[:tid]
        send_cmd.call('Page.enable', {}, sid)
        send_cmd.call('Runtime.addBinding', { name: '__drbNotify' }, sid)
        send_cmd.call('Page.addScriptToEvaluateOnNewDocument', { source: EARLY }, sid) if EARLY
        t[:due] = 0
      when :check
        next unless t
        v = o.dig('result', 'result', 'value')
        next unless v
        state = JSON.parse(v) rescue next
        unless state['core']
          # 로딩이 끝난 뒤에 주입 (로딩 중 주입하면 문서가 바뀌며 사라진다)
          if state['rs'] != 'loading'
            send_cmd.call('Runtime.evaluate', { expression: INJECT_EXPR, returnByValue: true }, t[:sid], { k: :inject, tid: tag[:tid] })
            t[:due] = now_ms + 1500
          else
            t[:due] = now_ms + 300
          end
          next
        end
        # 업데이트 요청 ([업데이트] 를 누르면 core.js 가 window.__drbUpdateRequest 를 만든다)
        if state['upd'] && !state_updating?
          set_updating(true)
          err = do_update(state['upd'])
          if err
            set_updating(false)
            log "update failed: #{err}"
            send_cmd.call('Runtime.evaluate', { expression: "window.__drbSkin&&window.__drbSkin.updateFailed&&window.__drbSkin.updateFailed(#{err.to_json})" }, t[:sid])
          end
        end
      when :inject
        log "inject #{tag[:tid]} #{t ? t[:url] : ''} -> #{o.dig('result', 'result', 'value')}"
      end
    end
    # 상태 확인: 바인딩으로 당겨진 화면은 즉시, 아니면 1초(바인딩 확인 후 2.5초)마다
    t_now = now_ms
    every = binding_ok ? 2500 : 1000
    targets.each do |tid, t|
      next unless t[:sid] && t[:url] =~ DOORAY_RE && t_now >= t[:due]
      send_cmd.call('Runtime.evaluate', { expression: CHECK_EXPR, returnByValue: true }, t[:sid], { k: :check, tid: tid })
      t[:due] = t_now + every
    end
    if t_now >= next_alive
      next_alive = t_now + 2000
      return :exit if dooray_pids.empty?
    end
  end
rescue StandardError => e
  log "cdp loop error: #{e.message}"
  :reconnect
ensure
  ws&.close
end

# 업데이트 진행 중 표시. 새 앱 실행이 실패해도 2분 뒤에는 다시 시도할 수 있게 만료시킨다
$updating_since = nil
def state_updating?
  $updating_since && (Time.now - $updating_since) < 120
end

def set_updating(v)
  $updating_since = v ? Time.now : nil
end

# ---------------------------------------------------------------- 감시: Dooray 가 Skin 없이 막 시작되면 디버그 포트로 다시 실행
# 대표 사례: Dooray 자체 업데이트(Squirrel/ShipIt)가 앱을 바꾸고 자동 재시작 → 디버그 포트 없이 뜸
def keeper_off?
  File.exist?(File.join(DATA, 'keeper.off'))
end

def watch_for_plain_dooray(port, restarts)
  seen_plain = {}
  loop do
    sleep 2
    pids = dooray_pids
    next if pids.empty?
    return :attach if version_info(port) # 우리 포트로 떠 있음 → 다시 붙는다
    pid = pids.first
    next if seen_plain[pid]
    age = age_seconds(pid)
    if keeper_off?
      seen_plain[pid] = true
      next
    end
    # 막 시작한 Dooray 만 대상. 그 사이 정상적으로 쓰던 Dooray 를 끄지 않는다.
    # 시작 후 6초는 기다려 준다(자동 재시작 직후 로그인 화면/업데이트 정리 중)
    next if age < 6
    seen_plain[pid] = true
    if age > 90
      log "Skin 없이 실행 중인 Dooray(pid #{pid}, #{age}초 전 시작)는 그대로 둠"
      next
    end
    recent = restarts.select { |t| Time.now - t < 600 }
    restarts.replace(recent)
    if recent.size >= 2
      log '10분 안에 두 번 다시 시작해 자동 복구를 잠시 멈춤'
      notify('Dooray 를 Skin 으로 다시 시작하지 못했습니다. Dooray Skin 을 직접 실행해 주세요.')
      next
    end
    restarts << Time.now
    log "Skin 없이 시작된 Dooray 감지(pid #{pid}, #{age}초 전) → 디버그 포트로 다시 실행"
    info = ensure_dooray_with_port(port)
    return :attach if info
    log '디버그 포트가 열리지 않음 (Dooray 가 막았을 수 있음)'
    notify('Dooray 가 Skin 연결을 허용하지 않습니다. 자세한 내용은 Dooray Skin 설치 안내를 확인해 주세요.')
  end
end

# ---------------------------------------------------------------- main
def main
  port = debug_port
  log "injector start · mac · Dooray #{APP_VERSION} · strategy=cdp-port · port=#{port}#{TEST ? ' (TEST)' : ''}"
  # 한 번에 하나만 감시한다. 이미 감시 중이면 Dooray 만 확인하고 끝낸다
  lock = File.open(File.join(DATA, 'injector.lock'), File::RDWR | File::CREAT, 0o644)
  holder = lock.flock(File::LOCK_EX | File::LOCK_NB)
  info = ensure_dooray_with_port(port)
  unless info
    log "[실패] 디버그 포트 #{port} 가 열리지 않았습니다 → Skin 을 적용하지 못했습니다"
    notify('Dooray 4.0.4 이상에서 Skin 을 연결하지 못했습니다. launcher.log 를 확인해 주세요.')
    exit 1
  end
  unless holder
    log '이미 다른 주입기가 감시 중 → Dooray 만 확인하고 종료'
    return
  end
  # 여기까지(Dooray 를 디버그 포트로 띄우는 것)가 성공하면 부모는 끝내고, 자식이 백그라운드(새 세션)에서 감시를 이어 간다.
  # 앱(래퍼)이 바로 끝나도 감시는 남는다. flock 은 fork 로 자식에게 이어진다.
  unless TEST
    child = fork
    if child
      Process.detach(child)
      log "백그라운드 감시 시작 (pid #{child})"
      exit 0
    end
    Process.setsid
    $stdin.reopen(File::NULL)
  end
  File.write(File.join(DATA, 'state.json'), JSON.generate(strategy: 'cdp-port', pid: Process.pid, appVersion: APP_VERSION, at: Time.now.utc.iso8601))
  restarts = []
  fails = 0
  loop do
    r = run_event_loop(port, nil)
    if r != :exit
      # 연결이 끊겼다. 포트까지 닫혔으면 Dooray 가 종료/재시작된 것(자체 업데이트 포함) → 감시 모드. 포트가 열려 있으면 일시 끊김이니 재연결
      if version_info(port)
        fails += 1
        if fails >= 6
          log '연결이 계속 끊겨 감시를 멈춤'
          break
        end
        sleep 2
        next
      end
      r = :exit
    end
    fails = 0
    log 'Dooray 종료(또는 포트 닫힘) → 감시 대기'
    break if ENV['DRB_ONESHOT'] == '1' # (시험용) 종료까지만
    watch_for_plain_dooray(port, restarts) # 반환하면 다시 붙을 수 있는 상태 → 루프 처음으로
  end
  log 'injector stop'
end

trap('TERM') { log 'SIGTERM'; exit 0 }
trap('INT') { exit 0 }
main
