-- gochuchamchi 최종 스키마
-- 변경 이력:
--   - users: name/phone/birthdate/gender/nationality/address 컬럼 추가 (애플리케이션 실제 사용 컬럼 기준)
--   - 전체 테이블 utf8mb4로 통일 (한글 등 멀티바이트 문자 저장 문제 해결)
--   - users.role에 'superadmin' 등급 추가 (user / seller / admin / superadmin)
--   - users: 계정 사용 정지(suspend) 컬럼 추가
--   - 기본 superadmin 계정 시드 추가 (재구축해도 관리자가 남도록)
--
-- ※ 이 파일은 gochuchamchi-spring 의 src/main/resources/schema.sql 과 같은 내용을 유지해야 한다.
--   terraform이 rds-schema-init.tf 에서 이 파일을 RDS에 적용한다(filemd5 트리거).

CREATE DATABASE IF NOT EXISTS gochuchamchi
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE gochuchamchi;

CREATE TABLE IF NOT EXISTS users (
  id bigint(20) NOT NULL AUTO_INCREMENT,
  username varchar(50) NOT NULL,
  name varchar(50) NOT NULL DEFAULT '',
  password varchar(255) NOT NULL,
  phone varchar(20) DEFAULT NULL,
  birthdate varchar(8) DEFAULT NULL,
  gender varchar(1) DEFAULT NULL,
  nationality varchar(20) DEFAULT NULL,
  address varchar(255) DEFAULT NULL,
  email varchar(100) DEFAULT NULL,
  -- user: 일반 회원 / seller: 판매자 / admin: 관리자 / superadmin: 최고 관리자
  -- (CustomUserDetailsService가 "ROLE_" + role.toUpperCase() 로 권한을 만드므로 소문자로 저장)
  role varchar(20) DEFAULT 'user',
  -- 계정 사용 정지: suspended_until 이 미래 시각이거나 suspended_permanent = 1 이면 로그인 차단
  suspended_until datetime DEFAULT NULL,
  suspended_permanent tinyint(1) NOT NULL DEFAULT 0,
  suspended_at datetime DEFAULT NULL,
  suspended_by varchar(50) DEFAULT NULL,
  created_at datetime DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS notices (
  id bigint(20) NOT NULL AUTO_INCREMENT,
  title varchar(255) NOT NULL,
  content text NOT NULL,
  author varchar(50) NOT NULL,
  pinned tinyint(1) NOT NULL DEFAULT 0,
  views int(11) NOT NULL DEFAULT 0,
  created_at datetime DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS products (
  id bigint(20) NOT NULL AUTO_INCREMENT,
  seller_id bigint(20) NOT NULL,
  brand varchar(100) NOT NULL,
  name varchar(255) NOT NULL,
  category varchar(50) NOT NULL,
  price int(11) NOT NULL,
  stock int(11) NOT NULL DEFAULT 0,
  image varchar(500) DEFAULT NULL,
  description text DEFAULT NULL,
  new_item tinyint(1) NOT NULL DEFAULT 1,
  active tinyint(1) NOT NULL DEFAULT 1,
  view_count int(11) NOT NULL DEFAULT 0,
  created_at datetime DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS product_sizes (
  id int(10) unsigned NOT NULL AUTO_INCREMENT,
  product_id int(10) unsigned NOT NULL,
  size_name varchar(10) NOT NULL,
  stock int(10) unsigned NOT NULL DEFAULT 0,
  sort_order int(10) unsigned NOT NULL DEFAULT 0,
  sold_out tinyint(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY product_id (product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =============================================================================
-- audit_logs / user_behavior_logs (2026-08-12 추가)
--
-- 왜 지금 추가하나
--   RDS 감사 로그에 QUERY_DML_NO_SELECT 를 켜자마자, 앱이 user_behavior_logs 에
--   INSERT 하다 에러코드 1146(테이블 없음)으로 실패하는 것이 드러났다. 홈 화면이
--   열릴 때마다 실패했고 5분치 로그에서만 266건이었다. 앱이 예외를 삼키고 200 을
--   반환해서 화면상으로는 정상이라 그동안 아무도 몰랐다 — 행동 로그 기능이 통째로
--   죽어 있었다. 원본을 대조하는 과정에서 audit_logs 도 함께 빠져 있는 것을 확인했다.
--
--   원인은 이 파일과 원본의 동기화 누락이다. gochuchamchi-spring 의 커밋
--   "feat: add security audit logging and private image delivery"(a288da1)에서
--   두 테이블이 추가됐는데 이 사본에 반영되지 않았다. 파일 상단 주석대로 두 파일은
--   같은 내용을 유지해야 한다 — 앱에 테이블이 추가되면 이 파일도 함께 갱신할 것.
--
--   아래 정의는 추정이 아니라 원본 schema.sql 에서 그대로 옮긴 것이다.
-- =============================================================================

-- 보안 및 중요 상태 변경 이력. 사용자 삭제 이후에도 이력을 보존하기 위해 외래 키를 두지 않는다.
CREATE TABLE IF NOT EXISTS audit_logs (
  id bigint(20) NOT NULL AUTO_INCREMENT,
  event_type varchar(64) NOT NULL,
  outcome varchar(16) NOT NULL,
  actor_user_id bigint(20) DEFAULT NULL,
  actor_username varchar(50) DEFAULT NULL,
  target_type varchar(32) DEFAULT NULL,
  target_id varchar(100) DEFAULT NULL,
  request_method varchar(10) DEFAULT NULL,
  request_path varchar(255) DEFAULT NULL,
  ip_address varchar(45) DEFAULT NULL,
  user_agent varchar(500) DEFAULT NULL,
  reason_code varchar(64) DEFAULT NULL,
  details varchar(1000) DEFAULT NULL,
  occurred_at datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_audit_occurred_at (occurred_at),
  KEY idx_audit_actor (actor_user_id, occurred_at),
  KEY idx_audit_event (event_type, outcome, occurred_at),
  KEY idx_audit_target (target_type, target_id, occurred_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 공개 콘텐츠의 서버 측 조회 기록. 클릭 추적이나 폼 입력값은 수집하지 않는다.
CREATE TABLE IF NOT EXISTS user_behavior_logs (
  id bigint(20) NOT NULL AUTO_INCREMENT,
  event_type varchar(64) NOT NULL,
  user_id bigint(20) DEFAULT NULL,
  anonymous_id char(36) NOT NULL,
  behavior_session_id char(36) NOT NULL,
  request_path varchar(255) NOT NULL,
  resource_type varchar(32) DEFAULT NULL,
  resource_id varchar(100) DEFAULT NULL,
  metadata varchar(1000) DEFAULT NULL,
  response_status smallint NOT NULL,
  occurred_at datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_behavior_occurred_at (occurred_at),
  KEY idx_behavior_user (user_id, occurred_at),
  KEY idx_behavior_anonymous (anonymous_id, occurred_at),
  KEY idx_behavior_session (behavior_session_id, occurred_at),
  KEY idx_behavior_event (event_type, occurred_at),
  KEY idx_behavior_resource (resource_type, resource_id, occurred_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =============================================================================
-- 기존 DB 마이그레이션
--
-- CREATE TABLE IF NOT EXISTS 는 이미 있는 테이블에 컬럼을 추가해주지 않는다.
-- 재구축 없이 운영 중인 RDS에도 계정 정지 컬럼이 생기도록 여기서 보정한다.
-- (RDS 엔진이 MariaDB 10.11 이라 ADD COLUMN IF NOT EXISTS 를 지원 -> 여러 번 실행해도 안전)
-- =============================================================================

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS suspended_until datetime DEFAULT NULL AFTER role,
  ADD COLUMN IF NOT EXISTS suspended_permanent tinyint(1) NOT NULL DEFAULT 0 AFTER suspended_until,
  ADD COLUMN IF NOT EXISTS suspended_at datetime DEFAULT NULL AFTER suspended_permanent,
  ADD COLUMN IF NOT EXISTS suspended_by varchar(50) DEFAULT NULL AFTER suspended_at;


-- =============================================================================
-- 기본 superadmin 계정
--
-- 목적: destroy/apply로 RDS를 재생성해도 최고 관리자가 남아있게 한다.
--       (기존에는 재구축 때마다 UPDATE users SET role=... 을 손으로 다시 실행해야 했음
--        — docs/pitfalls-checklist.md 참고)
--
-- role 값 'superadmin' 은 AdminUserService.ROLE_SUPERADMIN 과 일치해야 한다.
-- CustomUserDetailsService 가 "ROLE_" + role.toUpperCase() 로 만들므로 소문자로 저장한다.
--
-- 비밀번호: 로그인이 불가능하도록 "잠긴" 값을 넣는다.
--   bcrypt 형식($2a$12$ + 53자)은 유효하지만, 이 문자열은 어떤 평문을 해싱해서 나온 값이
--   아니라 난수로 생성한 것이다. 즉 대응하는 평문이 존재하지 않으므로 웹 로그인 폼으로는
--   어떤 비밀번호를 넣어도 인증에 성공할 수 없다.
--   (SecurityConfig가 순수 BCryptPasswordEncoder를 쓰므로 matches()가 항상 false를 반환.
--    형식을 깨진 문자열로 두면 인코더가 예외를 던져 500이 날 수 있어 형식은 유효하게 유지)
--
-- 실제로 이 계정으로 로그인해야 한다면 정상 bcrypt 해시로 교체한다.
--   UPDATE users SET password = '<BCryptPasswordEncoder로 생성한 해시>'
--    WHERE username = 'superadmin';
--   ※ AdminUserService.canManage() 가 superadmin 계정을 보호하므로 관리자 화면에서는
--     이 계정의 권한 변경·정지·비밀번호 교체가 불가능하다. 반드시 DB에서 직접 해야 한다.
--
-- INSERT IGNORE: username이 UNIQUE이므로 이미 있으면 건너뛴다.
--                (스키마는 apply마다 재적용되지만 기존 계정을 덮어쓰지 않음)
-- =============================================================================

INSERT IGNORE INTO users (username, name, password, role)
VALUES (
  'superadmin',
  '슈퍼관리자',
  '$2a$12$0SXiA4XzpKd38IT69PHpjMyj3Um3cIzgaIDQWDJG9/6eZbhjeudE7',
  'superadmin'
);

-- =============================================================================
-- 기본 admin 계정 3개 (수동 회원가입 + DB 권한 상승 과정 생략용)
--
-- 비밀번호 공통: 1q2w3e4r!  (실제 bcrypt 해싱값, 로그인 가능)
-- INSERT IGNORE: username UNIQUE라 이미 있으면 건너뜀 -> 재apply해도 안전
-- =============================================================================

INSERT IGNORE INTO users (username, name, password, role)
VALUES
  ('dnjstjr504', 'admin1', '$2b$12$OuUMGePzBJcyTZqJ3agRhufW8lH/ZZsrDD9zL/4lGf2Y0.FEYO/Uy', 'admin'),
  ('ak121231',   'admin2', '$2b$12$OuUMGePzBJcyTZqJ3agRhufW8lH/ZZsrDD9zL/4lGf2Y0.FEYO/Uy', 'admin'),
  ('wjdgus429',  'admin3', '$2b$12$OuUMGePzBJcyTZqJ3agRhufW8lH/ZZsrDD9zL/4lGf2Y0.FEYO/Uy', 'admin');
