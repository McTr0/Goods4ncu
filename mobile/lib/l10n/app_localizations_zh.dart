// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get aiAssistantTab => 'AI助手';

  @override
  String get aiError => '抱歉，出现了一些问题，请重试。';

  @override
  String get aiGreeting => '你好！我是续樟校园二手交易平台的智能助手。有什么我可以帮你的吗？';

  @override
  String get aiWillAutoRecognize => 'AI将自动识别商品信息';

  @override
  String get allCategories => '全部';

  @override
  String get appTitle => '校园集市';

  @override
  String get brand => '品牌';

  @override
  String get brandLabel => '品牌';

  @override
  String get books => '图书';

  @override
  String get buyNow => '发起成交意向';

  @override
  String get buyer => '买家';

  @override
  String get cancel => '取消';

  @override
  String get category => '分类';

  @override
  String get categoryLabel => '分类';

  @override
  String get chinese => '简体中文';

  @override
  String get chat => '聊天';

  @override
  String get chatWithSelf => '不能和自己聊天';

  @override
  String get clothingShoes => '服饰鞋包';

  @override
  String get comingSoon => '即将推出...';

  @override
  String get condition => '成色';

  @override
  String get conditionLabel => '成色';

  @override
  String get confirm => '确认';

  @override
  String get confirmPassword => '确认密码';

  @override
  String get connectionFailedRetry => '连接失败，请稍后重试';

  @override
  String get connectionRequestSent => '已发送连接请求，等待对方接受';

  @override
  String get contactSeller => '联系卖家';

  @override
  String get counterOfferAmount => '还价金额';

  @override
  String counterOfferBySeller(String amount) {
    return '卖家还价 ¥$amount';
  }

  @override
  String get createError => '发布失败';

  @override
  String get createListing => '发布商品';

  @override
  String get createListingAiNeedsRetry => '需要重试';

  @override
  String get createListingAiReady => 'AI 识别完成';

  @override
  String get createListingAiRecognizing => '小帮正在识别...';

  @override
  String get createListingAiSubtitle => '拍照或上传图片，小帮会帮你先填标题、分类、品牌和成色；你只需要确认。';

  @override
  String get createListingAiTitle => '先让小帮看一眼';

  @override
  String get createListingModeOffer => '我要出';

  @override
  String get createListingModeWanted => '我要收';

  @override
  String get createWantedPanelTitle => '描述你想收什么';

  @override
  String get createWantedPanelSubtitle => '写清预算、最低成色和你在意的细节；系统会帮你匹配同学正在出的物品。';

  @override
  String get createListingBasicInfo => '商品基础信息';

  @override
  String get createListingBasicInfoSubtitle => '这些信息会直接影响同学是否愿意点进来看。';

  @override
  String get createWantedBasicInfo => '收物基础信息';

  @override
  String get createWantedBasicInfoSubtitle => '把需求说清楚，愿意出的同学才知道是否匹配。';

  @override
  String get createListingBrandHint => '例如：Apple、Casio、NCU';

  @override
  String get createWantedBrandLabel => '偏好品牌';

  @override
  String get createWantedBrandHint => '不限，或例如：Apple、Casio';

  @override
  String get createListingBrandRequired => '请输入品牌或来源';

  @override
  String get createListingChangeImage => '更换图片';

  @override
  String get createListingConditionSection => '成色与瑕疵';

  @override
  String get createListingConditionSubtitle => '把不完美说清楚，反而更容易成交。';

  @override
  String get createWantedConditionSection => '最低要求';

  @override
  String get createWantedConditionSubtitle => '这是你愿意接受的最低成色和补充要求。';

  @override
  String get createListingDefectHint => '例如：屏幕有轻微划痕';

  @override
  String get createWantedRequirementHint => '例如：要带充电器、可接受轻微划痕';

  @override
  String get createWantedRequirementsLabel => '要求/备注';

  @override
  String get createWantedBudgetLabel => '预算上限（元） *';

  @override
  String get createListingDescriptionHint => '描述一下购买时间、使用频率、配件、取货地点等...';

  @override
  String get createListingDescriptionLabel => '描述（选填）';

  @override
  String get createListingDescriptionSection => '补充描述';

  @override
  String get createListingDescriptionSubtitle => '可选，但越具体越省沟通成本。';

  @override
  String get createWantedDescriptionHint => '描述你想用它做什么、希望在哪里交接、哪些点不能接受...';

  @override
  String get createWantedDescriptionLabel => '需求描述（选填）';

  @override
  String get createWantedDescriptionSection => '补充需求';

  @override
  String get createWantedDescriptionSubtitle => '可选，但越具体越容易收到靠谱推荐。';

  @override
  String createListingMissingFields(String fields) {
    return '还差 $fields';
  }

  @override
  String get createListingPriceInvalid => '请输入有效的价格数字';

  @override
  String get createListingPriceLabel => '价格（元） *';

  @override
  String get createListingPriceRequired => '请输入价格';

  @override
  String get createListingProgressBasics => '基础信息完整';

  @override
  String get createListingProgressCondition => '成色已确认';

  @override
  String get createListingProgressDescription => '补充细节';

  @override
  String get createListingProgressImage => '图片辅助识别';

  @override
  String get createListingProgressSubtitle => '按这个节奏补齐，发布就不会乱。';

  @override
  String get createListingProgressTitle => '发布进度';

  @override
  String get createListingReadyHint => '信息齐了，可以发布';

  @override
  String get createListingTitleHint => '例如：iPhone 13 Pro Max 256G';

  @override
  String get createWantedTitleHint => '例如：想收一台 iPad Air 或同档平板';

  @override
  String get createSuccess => '商品发布成功';

  @override
  String get dailyGoods => '生活用品';

  @override
  String get defects => '缺陷';

  @override
  String get defectsLabel => '缺陷';

  @override
  String get delete => '删除';

  @override
  String get deleteConfirm => '确定要删除这件商品吗？';

  @override
  String get removeFavoriteConfirm => '确定要从收藏中移除该商品吗？';

  @override
  String get favoriteRemoved => '已从收藏中移除';

  @override
  String get undo => '撤销';

  @override
  String get description => '描述';

  @override
  String get descriptionLabel => '描述';

  @override
  String get digitalAccessories => '数码配件';

  @override
  String get edit => '编辑';

  @override
  String get electronics => '电子产品';

  @override
  String get english => 'English';

  @override
  String get enterValidCounterAmount => '请输入有效的还价金额';

  @override
  String get error => '错误';

  @override
  String get fromGallery => '相册';

  @override
  String get homeTab => '首页';

  @override
  String get language => '语言';

  @override
  String get listSeparator => '、';

  @override
  String get listingDirectionAll => '全部';

  @override
  String get listingDirectionOffer => '出';

  @override
  String get listingDirectionWanted => '收';

  @override
  String get listingDetail => '商品详情';

  @override
  String loadFailed(String error) {
    return '加载失败: $error';
  }

  @override
  String get loading => '加载中...';

  @override
  String get loadMore => '加载更多';

  @override
  String get login => '登录';

  @override
  String get loginError => '登录错误';

  @override
  String get loginSuccess => '登录成功';

  @override
  String get logout => '退出登录';

  @override
  String get logoutConfirm => '确定要退出登录吗？';

  @override
  String get logoutSuccess => '退出登录成功';

  @override
  String memberSince(String date) {
    return '注册于 $date';
  }

  @override
  String get messagesTab => '消息';

  @override
  String get notificationsCenter => '通知中心';

  @override
  String get notificationsCenterSubtitle => '系统消息与提醒';

  @override
  String get myFavorites => '我的收藏';

  @override
  String get myFavoritesSubtitle => '您收藏的商品';

  @override
  String get watchlistEmpty => '你还没有收藏商品';

  @override
  String get notificationsEmpty => '暂无通知';

  @override
  String get markAllRead => '全部已读';

  @override
  String get markAllReadSuccess => '已将全部通知标记为已读';

  @override
  String get myListings => '我的发布';

  @override
  String get myListingsMenu => '查看和管理您的商品';

  @override
  String get myListingsTab => '我的发布';

  @override
  String get myOrders => '成交记录';

  @override
  String get myOrdersSubtitle => '查看线下成交意向与确认记录';

  @override
  String get allOrders => '全部';

  @override
  String get allNotifications => '全部';

  @override
  String get unreadOnly => '未读';

  @override
  String get buyerOrders => '我想收';

  @override
  String get sellerOrders => '我在出';

  @override
  String get orderAsBuyer => '收';

  @override
  String get orderAsSeller => '出';

  @override
  String get pay => '支付';

  @override
  String get markPaid => '已确认意向';

  @override
  String get reason => '取消原因（选填）';

  @override
  String get negotiationDetails => '议价详情';

  @override
  String get negotiationExpired => '议价已超时取消';

  @override
  String get connectionAccepted => '已接受连接';

  @override
  String get connectionRejected => '已拒绝连接';

  @override
  String get negotiationRejected => '议价已拒绝';

  @override
  String get noProducts => '暂无商品';

  @override
  String get homeColdStartTitle => '这里刚开始';

  @override
  String get homeColdStartBody => '还没有人发东西。你说一句想出什么或想找什么，别人就能看到——第一个开口的人最重要。';

  @override
  String get homeColdStartAction => '我先说一句';

  @override
  String get homeFilterEmpty => '这个筛选下没有东西。换个条件，或者直接说说你想要什么。';

  @override
  String get notFound => '未找到';

  @override
  String operationFailed(String error) {
    return '操作失败: $error';
  }

  @override
  String get other => '其他';

  @override
  String get optional => '选填';

  @override
  String get owner => '卖家';

  @override
  String get pendingNegotiation => '待处理议价';

  @override
  String get password => '密码';

  @override
  String get price => '价格';

  @override
  String get priceLabel => '价格';

  @override
  String get wantedBudgetShort => '预算';

  @override
  String get wantedMinimumCondition => '最低成色';

  @override
  String get wantedRequester => '需求方';

  @override
  String get wantedMatchesTitle => '匹配的可出商品';

  @override
  String get contactRequester => '联系需求方';

  @override
  String get recommendMyOffer => '推荐我的商品';

  @override
  String get wantedOwnerHint => '这是你自己的需求';

  @override
  String get wantedNoOfferToRecommend => '你还没有可推荐的在出商品';

  @override
  String get wantedRecommendSuccess => '已推荐给需求方';

  @override
  String get profile => '个人信息';

  @override
  String get profileLoadFailed => '个人资料加载失败';

  @override
  String get profileTab => '我的';

  @override
  String get campusMembershipVerified => '校园身份已验证';

  @override
  String get campusMembershipPending => '校园身份待验证';

  @override
  String get campusMembershipSuspended => '校园资格已暂停';

  @override
  String get campusMembershipRevoked => '校园资格已撤销';

  @override
  String get campusEmail => '学校邮箱';

  @override
  String get campusEmailHint => '学号@email.ncu.edu.cn';

  @override
  String get campusEmailRequired => '注册需要填写学校邮箱';

  @override
  String get verifyCampusIdentity => '验证校园身份';

  @override
  String get campusVerificationSendHint => '验证码将发送到你当前设置的学校邮箱，5 分钟内有效。';

  @override
  String get sendVerificationCode => '发送验证码';

  @override
  String get verificationCodeSent => '验证码已发送，请查看学校邮箱';

  @override
  String get verificationCode => '6 位验证码';

  @override
  String get confirmVerification => '确认验证';

  @override
  String get campusVerificationSuccess => '校园身份验证成功';

  @override
  String get campusSwitchTitle => '切换当前校园';

  @override
  String get campusSwitchDescription => '浏览、发布与交流都会限定在所选校园。每台设备可以独立选择。';

  @override
  String get campusActive => '当前校园';

  @override
  String get campusSwitchSuccess => '已切换当前校园';

  @override
  String get publishTab => '发布';

  @override
  String get purchaseFailed => '购买失败，请稍后重试';

  @override
  String get purchaseSuccess => '成交意向已发送，等待卖家确认';

  @override
  String recognitionFailed(String error) {
    return '识别失败: $error';
  }

  @override
  String get recognitionSuccess => '识别成功，已自动填充信息';

  @override
  String get register => '注册';

  @override
  String get registerError => '注册错误';

  @override
  String get registerSuccess => '注册成功';

  @override
  String requestFailed(int code) {
    return '请求失败: $code';
  }

  @override
  String get retry => '重试';

  @override
  String get searchHint => '搜索商品...';

  @override
  String get sellerAcceptedDealComplete => '卖家已接受，交易完成';

  @override
  String get sellerCounterOffered => '卖家已还价';

  @override
  String get send => '发送';

  @override
  String get sessionExpired => '会话已过期，请重新登录';

  @override
  String get settings => '设置';

  @override
  String get settingsSubtitle => '应用设置';

  @override
  String get nickname => '昵称';

  @override
  String get nicknameChange => '修改昵称';

  @override
  String get nicknameChangeSuccess => '昵称已更新';

  @override
  String get nicknameChangeHint => '设置后其他人将看到你的新昵称';

  @override
  String get nicknameConflict => '该昵称已被使用';

  @override
  String get nicknameEmpty => '昵称不能为空';

  @override
  String get userAgreement => '用户协议';

  @override
  String get userAgreementTitle => '用户协议与条款';

  @override
  String get userAgreementSubtitle => '了解平台规则与使用责任范围。';

  @override
  String get sold => '已售';

  @override
  String get status => '状态';

  @override
  String get submit => '提交';

  @override
  String get takePhoto => '拍照';

  @override
  String get tapCameraIconHint => '点击右上角相机图标拍照或选择图片';

  @override
  String get title => '标题';

  @override
  String get titleRequired => '请输入标题';

  @override
  String totalListings(int count) {
    return '共 $count 件商品';
  }

  @override
  String get tradeProtection => '线下成交提醒';

  @override
  String get tradeProtectionSubtitle => '平台不托管资金，请双方自行确认验货、交接和付款';

  @override
  String get typeMessage => '输入消息...';

  @override
  String get uploadFromCamera => '拍照上传';

  @override
  String get uploadFromGallery => '相册上传';

  @override
  String get username => '用户名';

  @override
  String get adminConsole => '管理后台';

  @override
  String get adminConsoleSubtitle => '系统概览与管理';

  @override
  String get adminOnly => '仅管理员可用';

  @override
  String get adminStatsTab => '统计';

  @override
  String get adminListingsTab => '商品';

  @override
  String get adminOrdersTab => '成交记录';

  @override
  String get adminUsersTab => '用户';

  @override
  String get adminTotalListings => '商品总数';

  @override
  String get adminActive => '在售';

  @override
  String get adminUsers => '用户总数';

  @override
  String get adminOrders => '成交记录总数';

  @override
  String get adminTrend7Days => '趋势 (7日)';

  @override
  String get changeRole => '修改角色';

  @override
  String get markShipped => '确认成交';

  @override
  String get markCompleted => '已确认成交';

  @override
  String get orderStatusUpdated => '成交记录状态已更新';

  @override
  String get userRoleUpdated => '用户角色已更新';

  @override
  String get adminTakedown => '强制下架 (Takedown)';

  @override
  String get adminTakedownConfirm => '确认下架';

  @override
  String adminTakedownConfirmMessage(String title) {
    return '确定要强制下架 \"$title\" 吗？';
  }

  @override
  String get adminTakedownSuccess => '商品已强制下架';

  @override
  String get adminBan => '封禁用户 (Ban)';

  @override
  String get adminBanConfirm => '确认封禁';

  @override
  String get adminBanConfirmMessage => '确定要封禁该用户吗？封禁后该用户所有登录状态将被清除。';

  @override
  String get adminBanSuccess => '用户已被封禁';

  @override
  String get adminUnban => '解封用户 (Unban)';

  @override
  String get adminUnbanSuccess => '用户已解封';

  @override
  String get adminSearchListingsPlaceholder => '搜索商品...';

  @override
  String get adminSearchUsersPlaceholder => '搜索用户...';

  @override
  String get adminNoUsersFound => '未找到用户';

  @override
  String get adminNoListingsFound => '未找到商品';

  @override
  String get adminSensitiveActionsLocked => '敏感操作已锁定';

  @override
  String get adminSensitiveActionsLockedSubtitle =>
      '查看不受影响；封禁、下架、角色与审核处置需要重新验证密码。';

  @override
  String get adminUnlockActions => '验证并解锁';

  @override
  String get adminReauthenticateTitle => '验证管理员身份';

  @override
  String get adminReauthenticateHint => '解锁后 10 分钟内可执行敏感操作';

  @override
  String get adminTotpCodeLabel => '动态验证码（已启用时必填）';

  @override
  String get adminTotpCodeHint => '来自身份验证器 App 的 6 位数字';

  @override
  String get agentPlanPendingHeader => '待确认操作（小帮提出，需你确认后执行）';

  @override
  String get agentPlanConfirmAction => '确认执行';

  @override
  String get undoDoneHeader => '已完成，还可以撤销';

  @override
  String get undoAction => '撤销';

  @override
  String undoRemainingSeconds(int seconds) {
    return '还剩 $seconds 秒';
  }

  @override
  String get undoSucceeded => '已撤销';

  @override
  String get undoConflict => '无法撤销';

  @override
  String get undoFailed => '撤销失败，请重试';

  @override
  String get intentPageTitle => '我想…';

  @override
  String get intentComposerPrompt =>
      '用自己的话说就行，不用填表。想出东西、想收东西、想找人、想找人帮忙、想约活动都可以。';

  @override
  String get intentComposerHint => '比如：宿舍要清空了，小冰箱能卖多少卖多少 / 想找人一起打羽毛球';

  @override
  String get intentKindGoodsOffer => '想出东西';

  @override
  String get intentKindGoodsSeek => '想收东西';

  @override
  String get intentKindCompanion => '想找人一起';

  @override
  String get intentKindHelp => '想找人帮忙';

  @override
  String get intentKindActivity => '想约活动';

  @override
  String get intentPriceWhatever => '能卖多少卖多少';

  @override
  String get intentPriceFree => '免费送';

  @override
  String get intentPriceFlexible => '价格可谈';

  @override
  String get intentTimeFlexible => '时间都行';

  @override
  String get intentSubmit => '说出来';

  @override
  String get intentPhotoAction => '拍一张，一次全发';

  @override
  String get intentPhotoWorking => '正在看这张照片…';

  @override
  String get intentPhotoSplit => '识别出几件，确认一下哪些要发';

  @override
  String get intentPhotoNothing => '这张照片没认出东西，已按你写的记下';

  @override
  String get intentSaving => '正在保存…';

  @override
  String get intentSaved => '已记下，有合适的会告诉你';

  @override
  String get intentSavedNotListed => '已记下。没写价格，所以不会出现在商品栅格里，但一样会撮合';

  @override
  String get intentMineHeader => '我说过的';

  @override
  String get intentMineEmpty => '还没说过什么。上面写一句就行。';

  @override
  String get intentDraftBadge => '待你确认';

  @override
  String get intentConfirmDraft => '确认';

  @override
  String get intentNoMatchesYet => '暂时还没有合适的';

  @override
  String get intentFulfilAction => '已经解决了';

  @override
  String get intentWithdrawAction => '算了';

  @override
  String get intentFulfilled => '已标记为解决';

  @override
  String get intentWithdrawn => '已撤回';

  @override
  String get intentFeedHeader => '大家在找什么';

  @override
  String get intentFeedEmpty => '现在还没有人在找东西。你可以先说一句，让别人看到。';

  @override
  String get intentRespondAction => '我能帮';

  @override
  String get intentRespondTitle => '回应';

  @override
  String get intentRespondHint => '说说你有什么、或者你能怎么帮';

  @override
  String get intentRespondSend => '发送';

  @override
  String get intentRespondSent => '已发送，对方会在消息里看到';

  @override
  String get priceDiscoveryTitle => '让小帮定价';

  @override
  String get priceDiscoveryStart => '让小帮定价';

  @override
  String get priceDiscoveryYourLimit => '你的底线（元）';

  @override
  String get priceDiscoveryBuyerHint => '你最多愿意付多少';

  @override
  String get priceDiscoverySellerHint => '你最少愿意收多少';

  @override
  String get priceDiscoverySubmit => '私下告诉小帮';

  @override
  String get priceDiscoveryWaiting => '已收到。等对方也说完就出结果——对方看不到你的数字。';

  @override
  String get priceDiscoveryNoDeal => '这次没谈拢。要不要直接聊聊？';

  @override
  String get priceDiscoveryAcceptInvite => '对方想用这个方式定价';

  @override
  String get priceDiscoveryAgree => '好，就这样';

  @override
  String get priceDiscoveryPreferHaggle => '我想直接谈';

  @override
  String get priceDiscoveryDeclined => '已改为直接沟通';

  @override
  String get priceDiscoveryInvalid => '请填一个合理的价格';

  @override
  String get agreementCardTitle => '说好的事';

  @override
  String get agreementSlotItem => '东西';

  @override
  String get agreementSlotPrice => '价格';

  @override
  String get agreementSlotTime => '时间';

  @override
  String get agreementSlotPlace => '地点';

  @override
  String get agreementSlotWho => '几个人';

  @override
  String get agreementSlotBring => '要带什么';

  @override
  String get agreementSlotConditions => '其他约定';

  @override
  String get agreementSuggestion => '小帮从聊天里读到的，要采纳吗？';

  @override
  String get agreementAdopt => '就这样';

  @override
  String get agreementWaitingOther => '等对方确认';

  @override
  String get agreementAgreed => '双方都确认了';

  @override
  String get agreementNotSet => '还没说';

  @override
  String get agreementSet => '填写';

  @override
  String get agreementSettle => '就这么定了';

  @override
  String get agreementSettled => '已定下';

  @override
  String get agreementStale => '这一项已经变了，请看最新的内容';

  @override
  String get handoffPromptTitle => '这次约定后来怎么样？';

  @override
  String get handoffHappened => '见到了，事情办成了';

  @override
  String get handoffMissed => '没见到';

  @override
  String get handoffOnTime => '对方准时';

  @override
  String get handoffLate => '对方迟到了';

  @override
  String get handoffThanks => '谢谢，已记下';

  @override
  String get handoffOnce => '只问一次，之后不能改';

  @override
  String get reputationNewcomer => '新同学，还没有记录';

  @override
  String reputationSummary(int completed, int onTime) {
    return '完成 $completed 次约定，准时 $onTime 次';
  }

  @override
  String priceDiscoveryMatched(String price) {
    return '谈成了，成交价 ¥$price';
  }

  @override
  String intentMatchCount(int count) {
    return '找到 $count 个可能合适的';
  }

  @override
  String get agentPlanExecuted => '操作已执行';

  @override
  String get agentPlanCancelled => '已取消该操作';

  @override
  String get fulfillWantedAction => '标记已完成';

  @override
  String get reopenWantedAction => '重新开启需求';

  @override
  String get wantedFulfilledHint => '该需求已完成，不再接收新的匹配和推荐';

  @override
  String get wantedFulfilledToast => '需求已标记完成';

  @override
  String get wantedReopenedToast => '需求已重新开启';

  @override
  String get agentPlanSecondConfirmTitle => '高风险操作，请再次确认';

  @override
  String get agentPlanSecondConfirmAction => '确认执行';

  @override
  String get adminReauthenticateSuccess => '管理员身份已验证，敏感操作已临时解锁';

  @override
  String get adminLoginAs => '以该用户登录';

  @override
  String adminLoginAsSuccess(String username) {
    return '已以 $username 身份登录';
  }

  @override
  String get adminLoginAsFailed => '登录失败';

  @override
  String get adminLoginAsConfirm => '确认登录';

  @override
  String get adminLoginAsWarning => '即将切换到该用户身份';

  @override
  String get adminViewListings => '查看商品';

  @override
  String get orderId => '记录编号';

  @override
  String get orderDetail => '成交详情';

  @override
  String get dealParties => '沟通双方';

  @override
  String get dealTimeline => '成交时间线';

  @override
  String get noOrders => '暂无成交记录';

  @override
  String get conditionLikeNew => '几乎全新';

  @override
  String get conditionGood => '较好';

  @override
  String get conditionFair => '一般';

  @override
  String get conditionPoor => '较差';

  @override
  String get buyerInitiatedNegotiation => '买家发起议价';

  @override
  String get cannotContactSeller => '无法联系卖家：缺少卖家信息';

  @override
  String get itemAlreadyPurchased => '哎呀，该商品太火爆，已经被别人抢先一步啦！';

  @override
  String get unknown => '未知';

  @override
  String get idLabel => 'ID：';

  @override
  String get ownerIdLabel => '卖家ID：';

  @override
  String orderNumber(String id) {
    return '成交记录 #$id';
  }

  @override
  String get joinedLabel => '注册时间：';

  @override
  String get roleLabel => '角色：';

  @override
  String unbanConfirmMessage(String username) {
    return '确定要解封用户 \"$username\" 吗？';
  }

  @override
  String get adminLoginAsAuditLogWarning => '此操作将以选定用户的身份登录并留下审计日志，确定吗？';

  @override
  String impersonationFailed(String error) {
    return '身份切换失败：$error';
  }

  @override
  String get infoDisclaimer => '本产品仅做信息发布，无担保和资金中介，也不收手续费';

  @override
  String get aboutPlatform => '关于我们';

  @override
  String get aboutPlatformSubtitle => '了解平台定位、使用方式与安全提醒。';

  @override
  String get infoPublishing => '信息发布';

  @override
  String get infoPublishingDesc => '本平台仅提供信息发布服务，用户通过发帖分享商品信息。平台不参与任何交易或支付环节。';

  @override
  String get contactThroughChat => '通过聊天联系';

  @override
  String get contactThroughChatDesc => '可直接通过应用内聊天功能联系卖家，沟通细节并自行安排线下交易。';

  @override
  String get safetyTips => '安全提示';

  @override
  String get safetyTipsDesc => '交换物品时请选择安全的公共场所，交易前请仔细核实物品状况。';

  @override
  String get platformDisclaimer =>
      '本平台仅作为信息发布服务提供方，任何线下交易行为风险自担。请保持警惕，注意人身和财产安全。';

  @override
  String get recommendedForYou => '为你推荐';

  @override
  String get similarRecommendations => '相似推荐';

  @override
  String get camera => '拍照';

  @override
  String get gallery => '相册';

  @override
  String get uploading => '上传中';

  @override
  String get avatarUpdated => '头像已更新';

  @override
  String get uploadFailed => '上传失败';

  @override
  String get emailLabel => '邮箱';

  @override
  String get emailChange => '修改邮箱';

  @override
  String get emailChangeHint => '输入 @email.ncu.edu.cn 邮箱';

  @override
  String get emailDomainError => '请输入有效的学校邮箱';

  @override
  String get emailChangeSuccess => '邮箱已更新';

  @override
  String get notSet => '未设置';

  @override
  String get homeHeroEyebrow => 'Goods4ncu Campus Market';

  @override
  String get homeHeroTitle => '今天想淘点什么？';

  @override
  String get homeHeroSubtitle => '输入商品、预算或用途，小帮可以陪你找；也可以直接往下逛同学们刚挂出的闲置。';

  @override
  String get homePromptHint => '找二手教材、轻薄本，或让小帮帮你卖闲置…';

  @override
  String get homePromptSubmitTooltip => '交给小帮';

  @override
  String get homeSuggestionTitle => '试试这样开始';

  @override
  String get homeThoughtLaptopLabel => '找轻薄本';

  @override
  String get homeThoughtLaptopPrompt => '预算 3000 元，帮我找一台适合写代码、方便带去教室的轻薄本';

  @override
  String get homeThoughtPriceLabel => '给闲置估价';

  @override
  String get homeThoughtPricePrompt => '我有一件闲置想卖，先问我几个问题，再帮我估一个合理价格';

  @override
  String get homeThoughtCopyLabel => '帮我写发布文案';

  @override
  String get homeThoughtCopyPrompt => '帮我一步步整理闲置信息，并生成一份真实可信的商品发布文案';

  @override
  String get homeThoughtNegotiateLabel => '替我礼貌议价';

  @override
  String get homeThoughtNegotiatePrompt => '帮我找值得买的数码好物，并在价格合适时替我发起礼貌议价';

  @override
  String get homeRecentTitle => '最近上新';

  @override
  String get homeRecentSubtitle => '看看同学们正在出什么闲置。';

  @override
  String get conversationLoadFailedTitle => '消息暂时没有加载出来';

  @override
  String get conversationEmptyTitle => '还没有会话';

  @override
  String get conversationEmptySubtitle => '从商品详情联系，或搜索同学开始一次会话。';

  @override
  String get findClassmate => '找同学';

  @override
  String conversationWaitingCount(int count) {
    return '等待你回应 · $count';
  }

  @override
  String get conversationFilterAll => '全部';

  @override
  String get conversationFilterRealtime => '实时';

  @override
  String get conversationFilterMail => '留言';

  @override
  String get lookupDialogTitle => '找同学';

  @override
  String get lookupDialogSubtitle => '输入用户名、完整邮箱或学号。对方关闭某种查找方式时，这里不会显示结果。';

  @override
  String get lookupFieldLabel => '查找内容';

  @override
  String get lookupFieldHint => '例如：小王 / 2024123456 / name@email.ncu.edu.cn';

  @override
  String get lookupMethodLabel => '查找方式';

  @override
  String get lookupMethodAuto => '自动识别';

  @override
  String get lookupMethodUsername => '用户名';

  @override
  String get lookupMethodStudentId => '学号';

  @override
  String get lookupMethodEmail => '邮箱';

  @override
  String get lookupSearchAction => '查找';

  @override
  String get lookupHint => '小提示：邮箱和学号必须完整输入；是否能被找到由对方在设置里决定。';

  @override
  String get lookupEmpty => '没有找到可联系的用户。可能是输入不完整，或对方没有开启这种查找方式。';

  @override
  String lookupMatchedWithListings(String method, int count) {
    return '通过$method匹配 · $count 件在售';
  }

  @override
  String lookupMatchedIdentifierWithListings(
    String method,
    String identifier,
    int count,
  ) {
    return '通过$method匹配：$identifier · $count 件在售';
  }

  @override
  String get viewClassmateListings => '查看TA的在售';

  @override
  String get contactAction => '联系';

  @override
  String classmateActiveListingsTitle(String username) {
    return '$username 的在售';
  }

  @override
  String get classmateListingsLoadFailedTitle => '在售商品暂时没加载出来';

  @override
  String get classmateListingsEmptyTitle => '暂时没有在售商品';

  @override
  String get classmateListingsEmptySubtitle => 'TA 当前没有公开 active 商品。';

  @override
  String get unnamedListing => '未命名商品';

  @override
  String listingPriceLine(String category, String price) {
    return '$category · ¥$price';
  }

  @override
  String get assistantName => '小帮';

  @override
  String get assistantSystemBadge => 'AI 助手';

  @override
  String get assistantInboxSubtitle => '找货、估价、发布、议价，都可以从这里开始';

  @override
  String get assistantHeaderSubtitle => '你的续樟校园交易助手 · 重要决定会先征求你的确认';

  @override
  String get assistantHistoryLoadFailed => '历史消息暂时没有加载出来，你仍然可以继续询问小帮。';

  @override
  String get assistantTyping => 'AI 正在输入...';

  @override
  String recordingStatus(int seconds) {
    return '录音中 ${seconds}s / 60s';
  }

  @override
  String get viewAction => '查看';

  @override
  String get invitationFallbackTitle => '想和你实时聊聊';

  @override
  String get declineNow => '现在不方便';

  @override
  String get connectNow => '接通';

  @override
  String get modeRealtime => '实时';

  @override
  String get modeMail => '留言';

  @override
  String get conversationStateDelivered => '已送达';

  @override
  String get conversationStateSynSent => '等待对方接通';

  @override
  String get conversationStateSynAck => '对方已回应，等待确认';

  @override
  String get conversationStateActive => '本次会话已接通';

  @override
  String get conversationStateDeclined => '这次没有接通';

  @override
  String get conversationStateCancelled => '邀请已取消';

  @override
  String get conversationStateExpired => '本次会话已结束';

  @override
  String get conversationStateClosed => '本次沟通已结束';

  @override
  String get conversationChooseTitle => '选择一段会话';

  @override
  String get conversationChooseSubtitle => '实时会话与留言都会在这里保持各自清晰的边界。';

  @override
  String get contactModePromptTitle => '你想怎样联系？';

  @override
  String contactContextUser(String username) {
    return '联系 $username';
  }

  @override
  String contactContextListing(String title) {
    return '关于《$title》';
  }

  @override
  String get contactFallbackUser => '这位同学';

  @override
  String get contactModeRealtimeTitle => '现在聊';

  @override
  String get contactModeRealtimeDescription => '发起 10 分钟实时邀请，对方接通后开始本次会话';

  @override
  String get contactModeMailTitle => '写封留言';

  @override
  String get contactModeMailDescription => '直接送达，不显示在线、输入中和已读状态';

  @override
  String get contactOpeningRequired => '请先写下你想说的话';

  @override
  String get contactMailSubjectRequired => '留言需要一个主题';

  @override
  String get contactRealtimeComposerTitle => '发起实时邀请';

  @override
  String get contactMailComposerTitle => '写封留言';

  @override
  String get contactMailSubjectLabel => '主题';

  @override
  String get contactMailSubjectHint => '例如：想了解一下成色';

  @override
  String get contactMailBodyLabel => '正文';

  @override
  String get contactRealtimeOpeningLabel => '对方接通前会看到这句话';

  @override
  String get contactMailBodyHint => '把问题和方便回复的时间一次说清楚…';

  @override
  String get contactRealtimeOpeningHint => '你好，请问这件商品现在还在吗？';

  @override
  String get contactMailSubmit => '送达留言';

  @override
  String get contactRealtimeSubmit => '等待对方接通';

  @override
  String get publicProfile => '同学主页';

  @override
  String get myPublicProfile => '我的公开主页';

  @override
  String get myPublicProfileSubtitle => '预览别人看到你的样子。';

  @override
  String get viewPublicProfile => '查看主页';

  @override
  String get publicProfileLoadFailed => '用户主页暂时没加载出来';

  @override
  String get publicProfileListingsTitle => '在售商品';

  @override
  String get publicProfileListingsEmpty => '暂时没有在售商品。';

  @override
  String get paymentQrSectionTitle => '线下收款码';

  @override
  String get paymentQrSectionSubtitle => '只有用户主动公开后才展示。平台不处理、不验证、不托管付款。';

  @override
  String get paymentQrPublicNotice => '请在确认商品和卖家后再线下付款；付款由双方自行约定。';

  @override
  String get wechatPayQr => '微信收款码';

  @override
  String get alipayQr => '支付宝收款码';

  @override
  String get paymentQrSettingsTitle => '收款码';

  @override
  String get paymentQrSettingsSubtitle => '可选。只有你开启公开展示后，才会显示在个人主页。';

  @override
  String get uploadWechatQr => '上传微信收款码';

  @override
  String get uploadAlipayQr => '上传支付宝收款码';

  @override
  String get showWechatQr => '展示微信收款码';

  @override
  String get showAlipayQr => '展示支付宝收款码';

  @override
  String get paymentQrUpdated => '收款码设置已更新';

  @override
  String get paymentQrCleared => '收款码已移除';

  @override
  String get paymentQrMissingHint => '请先上传收款码，再开启公开展示。';

  @override
  String get paymentQrSafetyHint => '平台只展示图片，不会确认对方是否已经付款。';

  @override
  String get createDealIntent => '发起成交意向';

  @override
  String get dealIntentSent => '成交意向已发送，等待卖家确认';

  @override
  String get platformNoEscrowShort =>
      '平台只记录线下成交意向，不托管资金、不确认付款或交付；请通过聊天确认验货、交接和付款方式。';

  @override
  String get awaitingSellerConfirm => '等待卖家确认';

  @override
  String get dealConfirmed => '已确认线下成交';

  @override
  String get dealCancelled => '成交记录已取消';

  @override
  String get confirmOfflineDeal => '确认成交';

  @override
  String get autoDelistAfterConfirm => '确认后自动下架商品';

  @override
  String get autoDelistAfterConfirmSubtitle => '适合单件闲置。关闭后商品会继续展示，方便你继续接收意向。';

  @override
  String get dealIntentCreated => '买家发起成交意向';

  @override
  String get sellerConfirmedDeal => '卖家确认成交';

  @override
  String get itemAutoDelisted => '商品已自动下架';

  @override
  String get listingStatus => '商品状态';

  @override
  String get chatReadReceiptSettingsTitle => '聊天已读策略';

  @override
  String get chatReadReceiptDefaultTitle => '默认已读方式';

  @override
  String get chatReadReceiptAutoTitle => '自动已读';

  @override
  String get chatReadReceiptManualTitle => '手动已读';

  @override
  String get chatReadReceiptAutoSubtitle => '打开实时聊天后自动标记收到的消息。';

  @override
  String get chatReadReceiptManualSubtitle => '只有点击“标记已读”后，对方才会看到已读。';

  @override
  String get chatReadReceiptAutoCurrent => '自动：打开实时聊天后自动标记已读。';

  @override
  String get chatReadReceiptManualCurrent => '手动：打开聊天不会自动让对方看到已读。';

  @override
  String get chatReadReceiptUpdated => '聊天已读策略已更新';

  @override
  String get markConversationRead => '标记已读';

  @override
  String get markConversationReadSuccess => '已标记为已读';

  @override
  String get manualReadUnreadOne => '有未读消息，当前为手动已读';

  @override
  String manualReadUnreadMany(int count) {
    return '$count 条未读消息，当前为手动已读';
  }

  @override
  String get readPreferenceUpdated => '已读策略已更新';

  @override
  String get readPreferenceInherit => '已读策略：继承默认';

  @override
  String get readPreferenceAuto => '已读策略：自动';

  @override
  String get readPreferenceManual => '已读策略：手动';

  @override
  String get selectedSuffix => ' ✓';

  @override
  String get quoteListing => '商品';

  @override
  String get quoteOrder => '成交记录';

  @override
  String get quoteHitlOffer => '议价';

  @override
  String get quoteGeneric => '引用';

  @override
  String get discoverabilitySettingsTitle => '别人如何找到我';

  @override
  String get discoverByUsernameTitle => '通过用户名找到我';

  @override
  String get discoverByUsernameSubtitle =>
      '关闭后，别人不能用用户名搜索到你；商品和既有会话里的必要展示不受影响。';

  @override
  String get discoverByEmailTitle => '通过邮箱找到我';

  @override
  String get discoverByEmailMissingSubtitle => '先设置学校邮箱后，才能选择是否允许别人用完整邮箱找到你。';

  @override
  String discoverByEmailSubtitle(String email) {
    return '当前邮箱：$email。开启后，别人必须输入完整邮箱才能找到你。';
  }

  @override
  String get discoverByStudentIdTitle => '通过学号找到我';

  @override
  String discoverByStudentIdSubtitle(String studentId) {
    return '已从邮箱推断学号：$studentId。开启后，别人必须输入完整学号才能找到你。';
  }

  @override
  String get discoverByStudentIdMissingSubtitle =>
      '当前邮箱无法识别学号；请使用 8-12 位数字开头的学校邮箱。';

  @override
  String get discoverabilityUpdated => '查找设置已更新';

  @override
  String settingsUpdateFailed(String error) {
    return '设置失败：$error';
  }

  @override
  String get conversationSectionDirect => '同学私聊';

  @override
  String get conversationSectionSpaces => '校园群组与频道';

  @override
  String get conversationSectionTools => '小帮';

  @override
  String get conversationCreateGroupSuccess => '群组已创建，已放入消息列表';

  @override
  String get conversationCreateChannelSuccess => '频道已创建，已放入消息列表';

  @override
  String conversationCreateFailed(String error) {
    return '创建失败：$error';
  }

  @override
  String get conversationPeerFallback => '同学';

  @override
  String get conversationThreadLoading => '读取会话中';

  @override
  String conversationThreadStats(int realtime, int mail, int count) {
    return '实时 $realtime · 留言 $mail · 共 $count 段';
  }

  @override
  String get conversationReconnect => '重新联系';

  @override
  String get conversationThreadLoadFailedTitle => '联系人线程暂时没加载出来';

  @override
  String get conversationThreadEmptyTitle => '还没有可显示的沟通记录';

  @override
  String get conversationThreadEmptySubtitle => '重新联系会创建一段新的实时聊天或留言。';

  @override
  String get conversationMailThreadTitle => '留言线程';

  @override
  String get conversationRealtimeThreadTitle => '实时会话';

  @override
  String get conversationSegmentHistoryHint => '这段沟通已保留为历史记录。需要继续时，请开启一段新的沟通。';

  @override
  String get conversationSegmentOpenHint => '进入这段沟通后，可以继续查看消息、回复、引用信息或处理接通状态。';

  @override
  String get conversationViewHistory => '查看历史';

  @override
  String get conversationOpenSegment => '打开这段沟通';

  @override
  String conversationPendingCount(int count) {
    return '待回应 $count';
  }

  @override
  String get conversationTimelineFallback => '查看沟通时间线';

  @override
  String conversationRealtimeCount(int count) {
    return '实时 $count';
  }

  @override
  String conversationMailCount(int count) {
    return '留言 $count';
  }

  @override
  String conversationSegmentCount(int count) {
    return '共 $count 段';
  }

  @override
  String get createGroup => '创建群组';

  @override
  String get createChannel => '创建频道';

  @override
  String get spaceNameLabel => '名称';

  @override
  String get spaceDescriptionOptionalLabel => '简介（可选）';

  @override
  String get createAction => '创建';

  @override
  String get unnamedSpace => '未命名空间';

  @override
  String get spaceFallbackTitle => '校园群组';

  @override
  String get refresh => '刷新';

  @override
  String get spaceLoadFailedTitle => '空间暂时没加载出来';

  @override
  String get spaceNotFoundTitle => '空间不存在';

  @override
  String get spaceNotFoundSubtitle => '它可能已被删除，或你还不是成员。';

  @override
  String spaceSendFailed(String error) {
    return '发送失败：$error';
  }

  @override
  String spaceMembersRoleLine(int count, String role) {
    return '$count 位成员 · 我的角色 $role';
  }

  @override
  String get spaceMessagesLoadFailedTitle => '空间消息暂时没加载出来';

  @override
  String get spaceChannelCreatedTitle => '频道已创建';

  @override
  String get spaceGroupCreatedTitle => '群组已创建';

  @override
  String get spaceChannelEmptySubtitle => '公告会出现在这里；频道成员可以阅读、反应和举报。';

  @override
  String get spaceGroupEmptySubtitle => '现在它已经在消息列表里了。发第一句话，让这个群组真的活起来。';

  @override
  String get replyAction => '回复';

  @override
  String replyPreviewMissing(int messageId) {
    return '回复了一条消息 #$messageId';
  }

  @override
  String get spaceChannelReadOnlyNotice =>
      '你是频道成员，可以阅读、反应和举报；只有频道 owner/admin 可以发布公告。';

  @override
  String get cancelReply => '取消回复';

  @override
  String get channelComposerHint => '发布一条公告...';

  @override
  String get groupComposerHint => '发一条群消息...';

  @override
  String spaceFallbackDescription(int count, String kind) {
    return '$count 位成员 · $kind';
  }

  @override
  String get spaceKindChannelLong => '公告频道';

  @override
  String get spaceKindGroupLong => '校园讨论群';

  @override
  String get spaceKindChannel => '频道';

  @override
  String get spaceKindGroup => '群组';

  @override
  String get spaceRoleOwner => '创建者';

  @override
  String get spaceRoleAdmin => '管理员';

  @override
  String get spaceRoleBanned => '已限制';

  @override
  String get spaceRoleMember => '成员';

  @override
  String get chatAcceptedLegacy => '已接受连接';

  @override
  String chatAcceptFailed(String error) {
    return '接受失败：$error';
  }

  @override
  String get chatRejectedLegacy => '已拒绝连接';

  @override
  String chatRejectFailed(String error) {
    return '拒绝失败：$error';
  }

  @override
  String get replyingToMessage => '正在回复这条消息';

  @override
  String reactionFailed(String error) {
    return '反应失败：$error';
  }

  @override
  String get hideMessageDialogTitle => '从我的聊天记录删除？';

  @override
  String get hideMessageDialogBody => '这只会从你这里隐藏，对方仍然可以看到这条消息。';

  @override
  String get deleteAction => '删除';

  @override
  String get messageHiddenForMe => '已从你的聊天记录隐藏';

  @override
  String messageHideFailed(String error) {
    return '删除失败：$error';
  }

  @override
  String get reportMessageTitle => '举报这条消息';

  @override
  String get reportReasonDefault => '不当内容';

  @override
  String get reportReasonLabel => '原因';

  @override
  String get reportDetailsLabel => '补充说明（可选）';

  @override
  String get submitAction => '提交';

  @override
  String get acceptAction => '接受';

  @override
  String get rejectAction => '拒绝';

  @override
  String get reportSubmitted => '已提交举报';

  @override
  String reportFailed(String error) {
    return '举报失败：$error';
  }

  @override
  String markReadFailed(String error) {
    return '标记已读失败：$error';
  }

  @override
  String readPreferenceUpdateFailed(String error) {
    return '已读策略更新失败：$error';
  }

  @override
  String get quoteUnavailable => '当前会话没有可引用的商品、订单或议价信息';

  @override
  String get quotePickerTitle => '引用相关信息';

  @override
  String get quotePickerSubtitle => '引用会由服务器生成事实快照，价格、标题和状态不会被前端伪造。';

  @override
  String get quoteListingFallback => '本次会话关联商品';

  @override
  String get quoteListingSubtitle => '发送时引用商品标题、价格、成色和主图快照';

  @override
  String get conversationCannotSendMessage => '本次会话暂时不能发送消息';

  @override
  String messageSendFailed(String error) {
    return '发送失败：$error';
  }

  @override
  String get replyAssistantUnavailable => '小帮暂时没想好，你仍可以直接输入';

  @override
  String closeConversationFailed(String error) {
    return '结束会话失败：$error';
  }

  @override
  String get blockUserTitle => '屏蔽这位用户？';

  @override
  String get blockUserBody => '双方将不能继续发送消息，已有历史仍会保留。';

  @override
  String get blockAction => '屏蔽';

  @override
  String blockFailed(String error) {
    return '屏蔽失败：$error';
  }

  @override
  String get callRequiresActiveConversation => '接通后才能发起通话';

  @override
  String get videoCallSignalSent => '视频通话信令已发送';

  @override
  String get audioCallSignalSent => '语音通话信令已发送';

  @override
  String callStartFailed(String error) {
    return '发起通话失败：$error';
  }

  @override
  String get secretChatCreated => '加密聊天会话已创建，服务器只保存密文接口';

  @override
  String secretChatCreateFailed(String error) {
    return '创建加密聊天失败：$error';
  }

  @override
  String quoteListingLabel(String title) {
    return '引用商品：$title';
  }

  @override
  String get conversationFallbackTitle => '会话';

  @override
  String get conversationLoadingState => '正在读取会话状态';

  @override
  String get conversationUnavailable => '这段会话当前不可用';

  @override
  String get conversationWaitingPeer => '等待对方接通';

  @override
  String get conversationAcceptToReply => '接通后即可回复';

  @override
  String get conversationCompletingHandshake => '正在完成接通确认';

  @override
  String get conversationDeclinedTitle => '这次没有接通';

  @override
  String get conversationCancelledTitle => '邀请已取消';

  @override
  String get conversationExpiredTitle => '本次会话已结束';

  @override
  String get conversationClosedTitle => '本次沟通已结束';

  @override
  String conversationReadMenuHeader(String mode) {
    return '已读设置 · 当前$mode';
  }

  @override
  String get readModeUnknown => '未知';

  @override
  String get readModeManual => '手动';

  @override
  String get readModeAuto => '自动';

  @override
  String get readModeInherit => '继承默认';

  @override
  String get audioCallMvp => '语音通话 MVP';

  @override
  String get videoCallMvp => '视频通话 MVP';

  @override
  String get secretChatMvp => '加密聊天 MVP';

  @override
  String get closeConversationAction => '结束本次沟通';

  @override
  String get replyAssistantButton => '小帮帮我回';

  @override
  String get mailFallbackTitle => '留言';

  @override
  String get mailProtocolSubtitle => '异步送达 · 不显示在线、输入中和已读状态';

  @override
  String get incomingRealtimeTitle => '对方想现在聊聊';

  @override
  String get incomingRealtimeSubtitle => '你可以选择是否接通';

  @override
  String incomingRealtimeExpiring(String remaining) {
    return '$remaining 后邀请失效';
  }

  @override
  String get notConvenientNow => '现在不方便';

  @override
  String get connectAction => '接通';

  @override
  String get waitingPeerTitle => '正在等待对方接通';

  @override
  String get invitationDelivered => '邀请已送达';

  @override
  String timeRemaining(String remaining) {
    return '还剩 $remaining';
  }

  @override
  String get cancelInvitation => '取消邀请';

  @override
  String get confirmingConnectionTitle => '正在确认接通';

  @override
  String get peerRespondedWaitingTitle => '已回应，等待对方确认';

  @override
  String get confirmingConnectionSubtitle => '确认完成后即可聊天';

  @override
  String connectionReleaseAfter(String remaining) {
    return '$remaining 后释放本次连接';
  }

  @override
  String get realtimeConnectedTitle => '本次会话已接通';

  @override
  String get realtimeConnectedSubtitle => '双方现在可以实时交流';

  @override
  String realtimeExpiresAfterIdle(String remaining) {
    return '无新消息 $remaining 后自动结束';
  }

  @override
  String get endAction => '结束';

  @override
  String get conversationTerminalSubtitle => '历史会保留；重新联系会开启一段新的沟通。';

  @override
  String get conversationNaturallyEndedTitle => '本次会话已自然结束';

  @override
  String durationHoursMinutes(int hours, int minutes) {
    return '$hours小时$minutes分';
  }

  @override
  String get connectionRequestTitle => '连接请求';

  @override
  String connectionRequestReadReceiptNotice(String title, String body) {
    return '$title\n\n$body\n\n确认后将开启消息已读功能';
  }

  @override
  String get offlineStatus => '离线';

  @override
  String get onlineStatus => '在线';

  @override
  String get pendingAcceptStatus => '待接受';

  @override
  String get connectingStatus => '连接中...';

  @override
  String get replyPreviewGeneric => '引用了一条消息';

  @override
  String get editedSuffix => '（已编辑）';

  @override
  String get editAction => '编辑';

  @override
  String get hideMessageAction => '从我的聊天记录删除';

  @override
  String get hideMessageActionSubtitle => '只会从你这里隐藏，对方仍可看到';

  @override
  String get reportAction => '举报';

  @override
  String get sendFailedShort => '发送失败';

  @override
  String get messageSentStatus => '已发送';

  @override
  String get messageReadStatus => '已读';

  @override
  String get messageDeliveredStatus => '已送达';

  @override
  String typingIndicator(String username) {
    return '$username 正在输入...';
  }

  @override
  String loadFailedWithError(String error) {
    return '加载失败：$error';
  }

  @override
  String get noMessagesYet => '暂无消息，开始聊天吧';

  @override
  String get stopAction => '停止';

  @override
  String get replyMediaMessage => '回复一条媒体消息';

  @override
  String get cancelQuote => '取消引用';

  @override
  String get quoteContextTooltip => '引用商品、订单或议价';

  @override
  String get editMessageHint => '编辑消息...';

  @override
  String get messageInputHint => '输入消息...';

  @override
  String offerPriceLine(String price) {
    return '报价：¥$price';
  }

  @override
  String reasonLine(String reason) {
    return '理由：$reason';
  }

  @override
  String expiresAtLine(String time) {
    return '有效期至：$time';
  }

  @override
  String get counterOfferAction => '还价';

  @override
  String get acceptCounterAction => '接受还价';

  @override
  String sellerCounterPriceLine(String price) {
    return '卖家还价 ¥$price';
  }

  @override
  String yourOriginalOfferLine(String price) {
    return '你的原始报价：¥$price';
  }

  @override
  String get connectionFailedNetwork => '连接失败，请检查网络';

  @override
  String get emptyReplyPlaceholder => '（无回复）';

  @override
  String listingLine(String listingId) {
    return '商品：$listingId';
  }

  @override
  String buyerOfferLine(String price) {
    return '买家报价：¥$price';
  }

  @override
  String statusLine(String status) {
    return '状态：$status';
  }

  @override
  String counterPriceLine(String price) {
    return '还价：¥$price';
  }

  @override
  String negotiationStatusLine(String status) {
    return '议价已$status';
  }

  @override
  String get adminModerationTab => '审核';

  @override
  String get moderationCenter => '内容审核';

  @override
  String get moderationCenterSubtitle => '查看与你有关的审核决定并提交申诉';

  @override
  String get moderationNoCases => '目前没有与你有关的审核案件';

  @override
  String get moderationReadOnly => '你可以查看本校案件；处置操作仅限平台管理员。';

  @override
  String get moderationCase => '审核案件';

  @override
  String get moderationResource => '相关内容';

  @override
  String get moderationReason => '公开原因';

  @override
  String get moderationCreatedAt => '创建时间';

  @override
  String get moderationResolution => '处理结果';

  @override
  String get moderationInternalEvidence => '内部证据';

  @override
  String get moderationStartReview => '开始复核';

  @override
  String get moderationRestrict => '限制内容';

  @override
  String get moderationDismiss => '确认无违规';

  @override
  String get moderationRestore => '恢复内容';

  @override
  String get moderationActionNote => '内部处置说明';

  @override
  String get moderationPublicReason => '向用户显示的原因（可选）';

  @override
  String get moderationActionSuccess => '案件状态已更新';

  @override
  String get moderationStatusOpen => '待处理';

  @override
  String get moderationStatusReviewing => '复核中';

  @override
  String get moderationStatusActioned => '已采取措施';

  @override
  String get moderationStatusDismissed => '无违规';

  @override
  String get moderationStatusAppealed => '申诉中';

  @override
  String get moderationStatusResolved => '已结案';

  @override
  String get moderationSourceMachine => '自动审核';

  @override
  String get moderationSourceUserReport => '用户举报';

  @override
  String get moderationSourceManual => '人工创建';

  @override
  String get moderationAppeal => '提交申诉';

  @override
  String get moderationAppealHint =>
      '请说明你认为判断有误的原因，以及审核人员需要重新核对的信息（10–2000 字）。';

  @override
  String get moderationAppealSubmitted => '申诉已提交，将由另一位审核人员复核';

  @override
  String get moderationPendingAppeal => '申诉等待复核';

  @override
  String get moderationCannotAppeal => '当前状态不能申诉';

  @override
  String get moderationFilterAll => '全部';

  @override
  String get moderationNoInternalDetails => '没有附加内部证据';

  @override
  String get listingImage => '商品图片';

  @override
  String get imageMessage => '聊天图片';

  @override
  String get avatar => '头像';

  @override
  String get warning => '警告';
}
