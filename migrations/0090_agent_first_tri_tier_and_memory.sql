-- Migration 0090: Agent-First Tri-Tier Intent Routing and Hierarchical Memory
--
-- 1. `intent_exemplars`: Semantically labeled exemplars for pgvector-backed
--    Tier 1 intent classification with cosine similarity.
-- 2. `user_agent_profiles`: Persistent user preferences, campus habits, custom
--    assistant instructions, and privacy controls.
-- 3. `agent_memories`: User episodic memories and preference facts with
--    vector embeddings, scoped to user and campus, with explicit user deletion controls.

-- ============================================================================
-- 1. Intent Exemplars (for Tier 1 Semantic Routing)
-- ============================================================================
CREATE TABLE IF NOT EXISTS intent_exemplars (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    intent_name VARCHAR(64) NOT NULL,
    example_text TEXT NOT NULL,
    category_hint TEXT,
    embedding vector(768),
    campus_id UUID REFERENCES campuses(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_intent_exemplars_intent_name ON intent_exemplars(intent_name);
CREATE INDEX IF NOT EXISTS idx_intent_exemplars_campus ON intent_exemplars(campus_id);

-- Seed initial exemplars covering primary student campus intents
INSERT INTO intent_exemplars (intent_name, example_text, category_hint) VALUES
    -- Search
    ('search', '帮我搜一下前湖校区有没有二手自行车', 'traffic'),
    ('search', '有没有考研数学张宇的书', 'book'),
    ('search', '搜索一下二手耳机或者音箱', 'digital'),
    ('search', '看看大家都在出什么闲置', 'all'),
    ('search', '有没有同学出ipad键盘', 'digital'),
    ('search', '我想找一把吉他', 'hobby'),
    ('search', '学校里有人卖电风扇或者小冰箱吗', 'appliance'),
    ('search', '求搜一下四级词汇书', 'book'),

    -- Buy (Purchase Intent / Immediate order interest)
    ('buy', '我要买这个耳机', 'digital'),
    ('buy', '怎么下单购买', 'order'),
    ('buy', '这个书我要了，怎么联系卖家购买', 'book'),
    ('buy', '我想直接买下这台显示器', 'digital'),
    ('buy', '这个商品我很满意，想要购买发起交易', 'order'),

    -- Offer (Publishing / Selling Goods)
    ('offer', '我想出掉宿舍里闲置的台灯，卖20块钱', 'appliance'),
    ('offer', '发布闲置：考研英语红宝书九成新，15元', 'book'),
    ('offer', '出一部自用iPhone 13，256G成色好', 'digital'),
    ('offer', '毕业出闲置行李箱和晾衣架', 'daily'),
    ('offer', '卖个二手篮球和打气筒', 'sports'),
    ('offer', '想把我的山地车出掉，前湖北院自取', 'traffic'),

    -- Wanted (Seeking Goods / Buy Request)
    ('wanted', '求购一个二手显示器，预算500以内', 'digital'),
    ('wanted', '我想收一本线性代数辅导书', 'book'),
    ('wanted', '收个九成新羽毛球拍', 'sports'),
    ('wanted', '求收二手吉他，南院可以面交', 'hobby'),

    -- Negotiate
    ('negotiate', '这个价格能便宜点吗', 'price'),
    ('negotiate', '180太贵了，150可以出吗', 'price'),
    ('negotiate', '能不能小刀一下', 'price'),
    ('negotiate', '跟卖家讲讲价，便宜十块钱行不行', 'price'),
    ('negotiate', '预算有限，希望能打个八折', 'price'),

    -- Companion / Study / Activity
    ('companion', '周末有没有一起去天健操场打羽毛球的搭子', 'sports'),
    ('companion', '找个同专业考研的一起去图书馆自习', 'study'),
    ('companion', '晚上润溪湖夜跑有人一起吗', 'sports'),
    ('companion', '周末想去爬梅岭，找两个校友组队', 'trip'),

    -- Help / Campus Assistance
    ('help', '有没有同学会修自行车的，求助', 'life'),
    ('help', '请问校医院周末开门吗', 'life'),
    ('help', '求问教务处补办学生证去哪栋楼', 'academic'),

    -- Chat / Casual
    ('chat', '你好呀小昌', 'greeting'),
    ('chat', '今天天气怎么样', 'casual'),
    ('chat', '你能帮我做些什么', 'intro'),
    ('chat', '南昌大学有哪些食堂比较好吃', 'casual')
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 2. User Agent Profiles (Preferences & Instructions)
-- ============================================================================
CREATE TABLE IF NOT EXISTS user_agent_profiles (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    preferred_locations TEXT[] NOT NULL DEFAULT '{}',
    interested_categories TEXT[] NOT NULL DEFAULT '{}',
    budget_preferences JSONB NOT NULL DEFAULT '{}'::jsonb,
    custom_instructions TEXT,
    privacy_level VARCHAR(32) NOT NULL DEFAULT 'standard',
    is_memory_enabled BOOLEAN NOT NULL DEFAULT true,
    is_proactive_enabled BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_agent_profiles_campus ON user_agent_profiles(campus_id);

-- ============================================================================
-- 3. Agent Memories (Hierarchical Episodic & Preference Memory)
-- ============================================================================
CREATE TABLE IF NOT EXISTS agent_memories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    campus_id UUID NOT NULL REFERENCES campuses(id) ON DELETE CASCADE,
    memory_type VARCHAR(32) NOT NULL, -- 'preference', 'deal_history', 'habit', 'custom_note', 'search_interest'
    content TEXT NOT NULL,
    embedding vector(768),
    source_ref VARCHAR(128),
    confidence REAL NOT NULL DEFAULT 1.0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_accessed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_agent_memories_user_campus ON agent_memories(user_id, campus_id);
CREATE INDEX IF NOT EXISTS idx_agent_memories_user_type ON agent_memories(user_id, memory_type);
