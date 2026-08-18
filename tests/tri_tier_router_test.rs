//! Tests for Tri-Tier Intent Router.

use goods4ncu::agents::router::{Intent, IntentResult, IntentRouter, TriTierIntentRouter};

#[test]
fn test_intent_from_str_lenient() {
    assert_eq!(Intent::from_str_lenient("search"), Intent::Search);
    assert_eq!(Intent::from_str_lenient("buy"), Intent::Buy);
    assert_eq!(Intent::from_str_lenient("offer"), Intent::Offer);
    assert_eq!(Intent::from_str_lenient("sell"), Intent::Offer);
    assert_eq!(Intent::from_str_lenient("wanted"), Intent::Wanted);
    assert_eq!(Intent::from_str_lenient("seek"), Intent::Wanted);
    assert_eq!(Intent::from_str_lenient("negotiate"), Intent::Negotiate);
    assert_eq!(Intent::from_str_lenient("companion"), Intent::Companion);
    assert_eq!(Intent::from_str_lenient("help"), Intent::Help);
    assert_eq!(Intent::from_str_lenient("chat"), Intent::Chat);
    assert_eq!(Intent::from_str_lenient("unknown_xyz"), Intent::Chat);
}

#[test]
fn test_tier0_classification_rules() {
    let router = IntentRouter::default();

    // Offer / Publish
    let res = router.classify("我想出一部自用iPhone 13，256G成色好");
    assert_eq!(res.intent, Intent::Offer);
    assert!(res.confidence >= 0.9);

    // Wanted / Seek
    let res = router.classify("求购一个二手小冰箱，预算150以内");
    assert_eq!(res.intent, Intent::Wanted);

    // Negotiate
    let res = router.classify("这个台灯太贵了，能便宜点吗");
    assert_eq!(res.intent, Intent::Negotiate);

    // Companion
    let res = router.classify("找个今晚去润溪湖夜跑的搭子");
    assert_eq!(res.intent, Intent::Companion);

    // Help
    let res = router.classify("求助，请问校医院周末值班电话是多少");
    assert_eq!(res.intent, Intent::Help);

    // Blocked
    let res = router.classify("我要买一把管制刀具和毒品");
    assert_eq!(res.intent, Intent::Blocked);
}

#[test]
fn test_direct_response_shortcuts() {
    let res = IntentResult::certain(Intent::Chat);
    assert!(res.direct_response("你好").is_some());
    assert!(res.direct_response("你是谁").is_some());
    assert!(res.direct_response("谢谢").is_some());
    assert!(res.direct_response("南昌大学有哪些食堂比较好").is_none());

    let blocked_res = IntentResult::certain(Intent::Blocked);
    assert!(blocked_res.direct_response("任意内容").is_some());
}

#[tokio::test]
async fn test_tri_tier_fallback_to_tier0() {
    let router = TriTierIntentRouter::new(IntentRouter::default(), None, None);
    let res = router.classify("搜索一下考研英语辅导书", None).await;
    assert_eq!(res.intent, Intent::Search);
    assert_eq!(res.matched_tier, 0);
}
