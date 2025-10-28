# Get-SBT Page Implementation - 双视角

**Date**: 2025-10-28
**Priority**: High
**Status**: Ready to implement

---

## 核心概念：双视角架构

### 视角切换逻辑

```typescript
// lib/utils/userRole.ts
import { useAccount } from 'wagmi';
import { useQuery } from '@apollo/client';
import { GET_USER_COMMUNITIES } from '@/lib/graphql/queries';

export enum UserRole {
  REGULAR_USER = 'user',      // 普通用户：查看自己的SBT
  COMMUNITY_OPERATOR = 'operator', // 社区运营者：管理社区成员
  DAO_ADMIN = 'admin'          // DAO管理员：全局配置
}

export function useUserRole() {
  const { address } = useAccount();

  // 1. 检查是否是社区运营者
  const { data: communities } = useQuery(GET_USER_COMMUNITIES, {
    variables: { operator: address },
    skip: !address
  });

  // 2. 检查是否是DAO管理员
  const { data: daoData } = useContractRead({
    address: MYSBT_ADDRESS,
    abi: MySBTABI,
    functionName: 'daoMultisig',
  });

  if (address === daoData) {
    return UserRole.DAO_ADMIN;
  }

  if (communities && communities.length > 0) {
    return UserRole.COMMUNITY_OPERATOR;
  }

  return UserRole.REGULAR_USER;
}
```

---

## 页面路由结构

```
/sbt
├── /                           # 根据角色重定向
│   ├── 普通用户 → /sbt/my
│   └── 社区运营者 → /sbt/operator
│
├── /my                         # 👤 用户视角：我的SBT
│   ├── /                       # SBT概览
│   ├── /communities            # 社区列表
│   ├── /activity               # 活动记录
│   └── /reputation             # 声誉详情
│
└── /operator                   # 🏛️ 运营者视角：社区管理
    ├── /                       # 社区概览
    ├── /members                # 成员管理
    ├── /analytics              # 数据分析
    └── /settings               # 社区设置
```

---

## 👤 视角1: 普通用户

### Page: `/sbt/my` - 我的SBT

```tsx
// app/sbt/my/page.tsx
'use client';

import { useAccount } from 'wagmi';
import { useQuery } from '@apollo/client';
import { GET_USER_SBT } from '@/lib/graphql/queries';
import { SBTCard, CommunityList, ReputationSummary } from '@/components/SBT';

export default function MySBTPage() {
  const { address } = useAccount();

  const { data, loading } = useQuery(GET_USER_SBT, {
    variables: { holder: address },
  });

  if (loading) return <LoadingSkeleton />;
  if (!data?.sbt) return <NoSBTView />;

  const sbt = data.sbt;

  return (
    <div className="container mx-auto py-8">
      <h1 className="text-3xl font-bold mb-8">My Soul Bound Token</h1>

      {/* SBT Overview Card */}
      <SBTCard sbt={sbt} />

      {/* Community Memberships */}
      <section className="mt-8">
        <h2 className="text-2xl font-semibold mb-4">
          My Communities ({sbt.totalCommunities})
        </h2>
        <CommunityList memberships={sbt.memberships} />
      </section>

      {/* Reputation Summary */}
      <section className="mt-8">
        <h2 className="text-2xl font-semibold mb-4">Reputation</h2>
        <ReputationSummary
          tokenId={sbt.id}
          memberships={sbt.memberships}
        />
      </section>

      {/* Recent Activities */}
      <section className="mt-8">
        <h2 className="text-2xl font-semibold mb-4">Recent Activities</h2>
        <ActivityTimeline
          tokenId={sbt.id}
          limit={10}
        />
      </section>
    </div>
  );
}
```

### Component: `SBTCard.tsx` - SBT卡片

```tsx
// components/SBT/SBTCard.tsx
import { SBT } from '@/lib/types';
import { formatAddress, formatDate } from '@/lib/utils';
import { Avatar } from '@/components/ui/avatar';

interface SBTCardProps {
  sbt: SBT;
}

export function SBTCard({ sbt }: SBTCardProps) {
  return (
    <div className="bg-gradient-to-br from-blue-500 to-purple-600 rounded-xl p-8 text-white shadow-lg">
      <div className="flex items-start justify-between">
        {/* Left: Avatar */}
        <div>
          <Avatar
            src={getAvatarURL(sbt)}
            alt={`SBT #${sbt.id}`}
            className="w-24 h-24 rounded-full border-4 border-white"
          />
        </div>

        {/* Right: Info */}
        <div className="flex-1 ml-6">
          <div className="flex items-center justify-between">
            <h2 className="text-2xl font-bold">MySBT #{sbt.id}</h2>
            <span className="bg-white/20 px-3 py-1 rounded-full text-sm">
              Soul Bound
            </span>
          </div>

          <div className="mt-4 space-y-2">
            <div className="flex items-center">
              <span className="text-white/70">Holder:</span>
              <span className="ml-2 font-mono">
                {formatAddress(sbt.holder)}
              </span>
            </div>

            <div className="flex items-center">
              <span className="text-white/70">Minted:</span>
              <span className="ml-2">{formatDate(sbt.mintedAt)}</span>
            </div>

            <div className="flex items-center">
              <span className="text-white/70">First Community:</span>
              <span className="ml-2">{sbt.firstCommunity}</span>
            </div>
          </div>

          {/* Stats */}
          <div className="mt-6 grid grid-cols-3 gap-4">
            <div className="bg-white/10 rounded-lg p-3 text-center">
              <div className="text-2xl font-bold">{sbt.totalCommunities}</div>
              <div className="text-sm text-white/70">Communities</div>
            </div>
            <div className="bg-white/10 rounded-lg p-3 text-center">
              <div className="text-2xl font-bold">{sbt.activities.length}</div>
              <div className="text-sm text-white/70">Activities</div>
            </div>
            <div className="bg-white/10 rounded-lg p-3 text-center">
              <div className="text-2xl font-bold">
                {calculateGlobalReputation(sbt)}
              </div>
              <div className="text-sm text-white/70">Global Rep</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
```

---

## 🏛️ 视角2: 社区运营者

### Page: `/sbt/operator` - 社区管理

```tsx
// app/sbt/operator/page.tsx
'use client';

import { useAccount } from 'wagmi';
import { useQuery } from '@apollo/client';
import { GET_OPERATED_COMMUNITIES } from '@/lib/graphql/queries';
import {
  CommunitySelector,
  CommunityStats,
  MemberList,
  ActivityChart
} from '@/components/Operator';

export default function OperatorDashboard() {
  const { address } = useAccount();

  // 查询用户运营的所有社区
  const { data } = useQuery(GET_OPERATED_COMMUNITIES, {
    variables: { operator: address },
  });

  const [selectedCommunity, setSelectedCommunity] = useState(
    data?.communities[0]
  );

  return (
    <div className="container mx-auto py-8">
      <div className="flex items-center justify-between mb-8">
        <h1 className="text-3xl font-bold">Community Dashboard</h1>

        {/* 社区选择器 */}
        <CommunitySelector
          communities={data?.communities || []}
          selected={selectedCommunity}
          onChange={setSelectedCommunity}
        />
      </div>

      {selectedCommunity && (
        <>
          {/* 统计概览 */}
          <CommunityStats community={selectedCommunity} />

          {/* 活动趋势图 */}
          <section className="mt-8">
            <h2 className="text-2xl font-semibold mb-4">Activity Trends</h2>
            <ActivityChart
              communityId={selectedCommunity.id}
              period="30d"
            />
          </section>

          {/* 成员列表 */}
          <section className="mt-8">
            <h2 className="text-2xl font-semibold mb-4">
              Members ({selectedCommunity.memberCount})
            </h2>
            <MemberList
              communityId={selectedCommunity.id}
              onMemberClick={(member) => {
                // 查看成员详情
                router.push(`/sbt/operator/members/${member.sbt.id}`);
              }}
            />
          </section>

          {/* Gnosis Safe 管理 */}
          {isGnosisSafe(address) && (
            <section className="mt-8">
              <GnosisSafeActions community={selectedCommunity} />
            </section>
          )}
        </>
      )}
    </div>
  );
}
```

### Component: `MemberList.tsx` - 成员列表（运营者视角）

```tsx
// components/Operator/MemberList.tsx
import { useQuery } from '@apollo/client';
import { GET_COMMUNITY_MEMBERS } from '@/lib/graphql/queries';

interface MemberListProps {
  communityId: string;
  onMemberClick?: (member: Member) => void;
}

export function MemberList({ communityId, onMemberClick }: MemberListProps) {
  const { data, loading } = useQuery(GET_COMMUNITY_MEMBERS, {
    variables: { communityId },
  });

  if (loading) return <Skeleton />;

  return (
    <div className="bg-white rounded-lg shadow overflow-hidden">
      <table className="min-w-full divide-y divide-gray-200">
        <thead className="bg-gray-50">
          <tr>
            <th>Member</th>
            <th>SBT ID</th>
            <th>Reputation</th>
            <th>Joined</th>
            <th>Last Active</th>
            <th>Activities (30d)</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody className="bg-white divide-y divide-gray-200">
          {data?.memberships.map((membership) => (
            <tr
              key={membership.id}
              className="hover:bg-gray-50 cursor-pointer"
              onClick={() => onMemberClick?.(membership)}
            >
              <td className="px-6 py-4">
                <div className="flex items-center">
                  <Avatar src={getAvatarURL(membership.sbt)} />
                  <span className="ml-3 font-mono text-sm">
                    {formatAddress(membership.sbt.holder)}
                  </span>
                </div>
              </td>
              <td className="px-6 py-4">#{membership.sbt.id}</td>
              <td className="px-6 py-4">
                <ReputationBadge
                  score={getReputationScore(membership)}
                />
              </td>
              <td className="px-6 py-4">{formatDate(membership.joinedAt)}</td>
              <td className="px-6 py-4">
                {membership.lastActivityTime
                  ? formatRelativeTime(membership.lastActivityTime)
                  : 'Never'}
              </td>
              <td className="px-6 py-4">{membership.activityCount}</td>
              <td className="px-6 py-4">
                <button className="text-blue-600 hover:text-blue-800">
                  View Details
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
```

---

## 🔐 Gnosis Safe 集成

### Setup Safe Apps SDK

```bash
npm install @safe-global/safe-apps-sdk @safe-global/safe-apps-react-sdk
```

### Component: `GnosisSafeActions.tsx`

```typescript
// components/Operator/GnosisSafeActions.tsx
import { useSafeAppsSDK } from '@safe-global/safe-apps-react-sdk';
import { useContractWrite } from 'wagmi';

export function GnosisSafeActions({ community }: { community: Community }) {
  const { sdk, safe } = useSafeAppsSDK();

  const proposeSetMinLockAmount = async (newAmount: bigint) => {
    const txs = [{
      to: MYSBT_ADDRESS,
      value: '0',
      data: encodeFunctionData({
        abi: MySBTABI,
        functionName: 'setMinLockAmount',
        args: [newAmount],
      }),
    }];

    // 发送到Safe - 需要多签批准
    await sdk.txs.send({ txs });

    toast.success('Proposal created! Waiting for signatures...');
  };

  return (
    <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-6">
      <div className="flex items-center mb-4">
        <Shield className="w-6 h-6 text-yellow-600 mr-2" />
        <h3 className="text-lg font-semibold">Gnosis Safe Actions</h3>
      </div>

      <p className="text-sm text-gray-600 mb-4">
        You are operating as a Gnosis Safe multisig. All actions require {safe.threshold} of {safe.owners.length} signatures.
      </p>

      <div className="space-y-3">
        <button
          onClick={() => proposeSetMinLockAmount(5n * 10n ** 18n)}
          className="w-full btn btn-warning"
        >
          Propose: Set Min Lock Amount to 5 GT
        </button>

        <button className="w-full btn btn-warning">
          Propose: Update Community Settings
        </button>
      </div>

      <div className="mt-4 text-xs text-gray-500">
        <a
          href={`https://app.safe.global/${safe.chainId}:${safe.safeAddress}`}
          target="_blank"
          className="text-blue-600 hover:underline"
        >
          View pending proposals in Safe →
        </a>
      </div>
    </div>
  );
}
```

---

## GraphQL Queries

```graphql
# queries.graphql

# 用户视角：获取我的SBT
query GetUserSBT($holder: Bytes!) {
  sbt(id: $holder) {
    id
    holder
    firstCommunity
    mintedAt
    totalCommunities
    memberships {
      community { id name }
      joinedAt
      isActive
      activityCount
      lastActivityTime
    }
    activities(first: 10, orderBy: timestamp, orderDirection: desc) {
      week
      timestamp
      community { name }
    }
    reputationScores {
      community { name }
      score
      baseScore
      nftBonus
      activityBonus
    }
  }
}

# 运营者视角：获取社区成员
query GetCommunityMembers($communityId: String!) {
  community(id: $communityId) {
    id
    name
    memberCount
    memberships(orderBy: activityCount, orderDirection: desc) {
      sbt {
        id
        holder
      }
      joinedAt
      isActive
      activityCount
      lastActivityTime
    }
  }
}

# 运营者视角：社区统计
query GetCommunityStats($communityId: String!) {
  community(id: $communityId) {
    id
    name
    memberCount
    activities(first: 1000, orderBy: timestamp, orderDirection: desc) {
      timestamp
    }
  }
}
```

---

## 实施清单

### Week 1: 基础框架
- [ ] 创建路由结构
- [ ] 实施角色检测逻辑
- [ ] Setup Apollo Client
- [ ] 基础组件 (SBTCard, CommunityList)

### Week 2: 用户视角
- [ ] /sbt/my 页面
- [ ] 声誉展示组件
- [ ] 活动时间线
- [ ] NFT 绑定功能

### Week 3: 运营者视角
- [ ] /sbt/operator 页面
- [ ] 成员管理列表
- [ ] 社区统计图表
- [ ] 数据导出功能

### Week 4: Gnosis Safe集成
- [ ] Safe Apps SDK 集成
- [ ] 多签操作界面
- [ ] 提案创建/查看
- [ ] 测试 + 文档

---

## 开发环境设置 (免费)

```bash
# 1. 使用Sepolia测试网 - 完全免费
# 2. The Graph Studio - 免费测试网查询
# 3. Vercel - 免费前端托管

# 环境变量 (.env.local)
NEXT_PUBLIC_CHAIN_ID=11155111  # Sepolia
NEXT_PUBLIC_MYSBT_ADDRESS=0x...  # 部署后填入
NEXT_PUBLIC_GRAPH_URL=https://api.studio.thegraph.com/query/.../mysbt-v2/v0.0.1
NEXT_PUBLIC_ALCHEMY_KEY=your_free_key  # Alchemy免费额度
```

---

**Status**: Ready to implement
**Timeline**: 4 weeks
**Cost**: $0 for development (all free tools)
**Deployment**: Vercel (free)
