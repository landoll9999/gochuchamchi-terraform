"""정책 엔진 — (심각도 × AI 판정)으로 무엇을 어떻게 알릴지 정한다.

로그 담당자 요구 구조를 그대로 표로 옮긴 것이다.

    심각도      TRUE_POSITIVE   UNCERTAIN   FALSE_POSITIVE
    CRITICAL    긴급            긴급        긴급        (AI 결과와 무관)
    HIGH        긴급            검토 필요   오탐 의심    (알림은 나간다)
    MEDIUM      알림            검토        억제        ← 알림이 사라지는 유일한 칸
    LOW         알림            저장        저장

이 파일이 별도로 존재하는 이유
    "무엇을 알릴지"는 운영하며 계속 바뀌는 판단이고, "AI를 어떻게 부를지"는
    거의 안 바뀌는 배관이다. 둘을 한 파일에 두면 정책을 손볼 때마다 호출
    코드를 건드리게 된다. 표만 고쳐서 정책을 바꿀 수 있어야 한다.

    표 자체도 Terraform 변수(triage_policy_matrix)로 주입되므로, 코드 배포
    없이 tfvars만 고쳐 정책을 바꿀 수 있다.

두 가지를 스펙에서 보강했다

    ① 억제에 confidence 하한을 걸었다.
       MEDIUM × FALSE_POSITIVE 는 이 표에서 알림이 사라지는 유일한 칸이고,
       곧 미탐이 생길 수 있는 유일한 자리다. 모델이 확신 0.3으로
       FALSE_POSITIVE를 뱉어도 묻히면 안 되므로, 하한 미만이면 UNCERTAIN으로
       강등해 "검토"로 보낸다. confidence를 스키마에 넣어 놓고 정책에서 안 쓰면
       그 필드는 장식이다.

    ② 타입이 중요하면 severity가 낮아도 티어를 올린다.
       EventBridge 룰 (A) 갈래는 루트 사용·자격증명 탈취 같은 타입을
       **severity와 무관하게** 통과시킨다. 그런데 이 환경의 finding은 실제로
       거의 전부 severity 2(LOW)다(2026-08-12-ai-triage.md §5).
       티어를 severity로만 정하면 **가장 중요한 finding이 전부 LOW로 떨어져
       AI 판정도 못 받고 저장만 된다.** 이전 구현이 같은 함정을 문서로 남겼다.
       그래서 always-notify 타입은 최소 HIGH로 올린다.
"""

import logging

LOG = logging.getLogger()

# GuardDuty severity(1~10) → 티어. AWS 콘솔이 쓰는 구간과 같게 맞춘다.
SEVERITY_TIERS = (
    (9.0, "CRITICAL"),
    (7.0, "HIGH"),
    (4.0, "MEDIUM"),
    (0.0, "LOW"),
)

TIER_ORDER = ["LOW", "MEDIUM", "HIGH", "CRITICAL"]

# 액션 → (알림을 보내는가, 표시 문구, 아이콘, 색)
# 색은 Discord embed 용. 판정이 아니라 **액션**이 색을 정한다 — 받는 사람이
# 먼저 봐야 하는 것은 "이게 얼마나 급한가"이지 "모델이 뭐라 했나"가 아니다.
ACTIONS = {
    "urgent": (True, "긴급", "🚨", 0xE01E5A),
    "alert": (True, "알림", "🔴", 0xED8936),
    "review": (True, "검토 필요", "🟡", 0xECC94B),
    "likely_fp": (True, "오탐 의심", "⚪", 0xA0AEC0),
    "suppress": (False, "억제", "🔇", 0x718096),
    "store": (False, "저장만", "📦", 0x718096),
}

# 정책 표에 없는 조합을 만났을 때. 조용해지는 쪽이 아니라 알리는 쪽으로 떨어진다.
FALLBACK_ACTION = "review"


def severity_tier(severity):
    """GuardDuty severity 숫자를 티어 문자열로."""
    try:
        value = float(severity)
    except (TypeError, ValueError):
        # severity를 못 읽으면 낮게 보지 않는다 — 모르는 것은 위험한 것으로 다룬다
        LOG.warning("severity를 해석할 수 없습니다(%r). HIGH로 처리합니다.", severity)
        return "HIGH"

    for threshold, tier in SEVERITY_TIERS:
        if value >= threshold:
            return tier
    return "LOW"


def max_tier(left, right):
    if left not in TIER_ORDER:
        return right
    if right not in TIER_ORDER:
        return left
    return TIER_ORDER[max(TIER_ORDER.index(left), TIER_ORDER.index(right))]


def effective_tier(severity, finding_type, always_notify_prefixes, type_prefix_min_tier):
    """실제 정책에 쓸 티어.

    severity만 보면 안 되는 이유는 파일 상단 ②를 볼 것. 타입이 "항상 통보"
    목록에 걸리면 최소 티어를 보장한다.
    """
    tier = severity_tier(severity)

    finding_type = finding_type or ""
    if any(finding_type.startswith(prefix) for prefix in always_notify_prefixes):
        raised = max_tier(tier, type_prefix_min_tier)
        if raised != tier:
            LOG.info("타입 %s 이(가) 항상통보 목록에 걸려 티어를 %s → %s 로 올립니다.",
                     finding_type, tier, raised)
        return raised

    return tier


def decide(tier, verdict, confidence, matrix, suppress_min_confidence):
    """(티어, 판정) → 액션.

    verdict가 None(판정 실패)이면 UNCERTAIN으로 취급한다. 모델을 못 불렀다고
    조용해지면 모델 가용성이 곧 탐지 가용성이 된다.
    """
    resolved_verdict = verdict or "UNCERTAIN"
    demoted = False

    # ① 억제는 확신이 충분할 때만. 아니면 UNCERTAIN(=검토)으로 강등.
    if resolved_verdict == "FALSE_POSITIVE" and confidence < suppress_min_confidence:
        LOG.info(
            "FALSE_POSITIVE 이지만 확신 %.2f < %.2f 이라 UNCERTAIN 으로 강등합니다.",
            confidence, suppress_min_confidence,
        )
        resolved_verdict = "UNCERTAIN"
        demoted = True

    action = (matrix.get(tier) or {}).get(resolved_verdict)

    if action not in ACTIONS:
        LOG.warning(
            "정책 표에 (%s, %s) 조합이 없습니다. %s 로 처리합니다.",
            tier, resolved_verdict, FALLBACK_ACTION,
        )
        action = FALLBACK_ACTION

    notify, label, icon, color = ACTIONS[action]

    return {
        "action": action,
        "notify": notify,
        "label": label,
        "icon": icon,
        "color": color,
        "tier": tier,
        # 원본 판정과 정책에 실제로 쓰인 판정을 둘 다 남긴다. 강등이 일어났을 때
        # "모델은 오탐이라 했는데 왜 검토로 왔나"에 답할 수 있어야 한다.
        "verdict_used": resolved_verdict,
        "verdict_demoted": demoted,
    }
