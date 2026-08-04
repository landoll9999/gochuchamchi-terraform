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
