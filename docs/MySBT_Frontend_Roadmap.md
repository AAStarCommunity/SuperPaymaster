# MySBT Frontend Roadmap

**Version**: v2.2
**Date**: 2025-10-28
**Status**: Planning → Implementation

## Overview

Complete frontend implementation for MySBT v2.2, including Get-SBT page, reputation display, activity tracking, and community management.

---

## Phase 1: Get-SBT Page (Core)

### User Story
> As a user, I want to view my SBT, see all my community memberships, check my reputation scores, and bind NFTs for bonus rewards.

### Features

#### 1.1 SBT Overview Card
```typescript
// Components to build:
components/
├── SBT/
│   ├── SBTCard.tsx              // Main SBT display
│   ├── SBTAvatar.tsx            // NFT avatar with fallback
│   ├── SBTMetadata.tsx          // Token ID, mint date, holder
│   └── SBTStats.tsx             // Total communities, activities

Design mockup:
┌────────────────────────────────────────┐
│  🖼️ Avatar          MySBT #1234       │
│                                         │
│  Holder: 0x1234...5678                 │
│  Minted: Oct 28, 2025                  │
│  First Community: SuperPaymaster       │
│                                         │
│  📊 Stats                              │
│  • 5 Communities                       │
│  • 234 Activities (Last 30 days)      │
│  • Global Reputation: 127              │
└────────────────────────────────────────┘
```

#### 1.2 Community Memberships List
```typescript
components/SBT/CommunityList.tsx

┌────────────────────────────────────────┐
│  My Communities (5)           [+ Join] │
│                                         │
│  ┌──────────────────────────────┐     │
│  │ 🏛️ SuperPaymaster            │     │
│  │ Joined: Oct 1, 2025          │     │
│  │ Reputation: 23  Activity: 🟢 │     │
│  │ [View Details] [Bind NFT]    │     │
│  └──────────────────────────────┘     │
│                                         │
│  ┌──────────────────────────────┐     │
│  │ 🎮 GameFi DAO                │     │
│  │ Joined: Sep 15, 2025         │     │
│  │ Reputation: 31  Activity: 🟢 │     │
│  │ NFT Bound: 🖼️ #4567          │     │
│  │ [View Details] [Unbind]      │     │
│  └──────────────────────────────┘     │
└────────────────────────────────────────┘
```

#### 1.3 Reputation Breakdown
```typescript
components/SBT/ReputationCard.tsx

┌────────────────────────────────────────┐
│  Community Reputation: SuperPaymaster  │
│                                         │
│  Total Score: 23                        │
│  ├─ Base Score: 20                     │
│  ├─ NFT Bonus: 0 (No NFT bound)       │
│  └─ Activity Bonus: 3 (3 weeks)       │
│                                         │
│  📊 Activity Chart (Last 4 weeks)      │
│  Week 1: ████████ (8 activities)       │
│  Week 2: ██████ (6 activities)         │
│  Week 3: ████ (4 activities)           │
│  Week 4: ████████ (8 activities)       │
│                                         │
│  [View Full History]                   │
└────────────────────────────────────────┘
```

#### 1.4 NFT Binding Interface
```typescript
components/SBT/NFTBindingModal.tsx

┌────────────────────────────────────────┐
│  Bind NFT for +3 Reputation Bonus     │
│                                         │
│  Your NFTs:                            │
│                                         │
│  ┌─────┐  ┌─────┐  ┌─────┐           │
│  │ 🖼️  │  │ 🖼️  │  │ 🖼️  │           │
│  │#1234│  │#5678│  │#9012│           │
│  └─────┘  └─────┘  └─────┘           │
│  [Select]  [Select]  [Select]         │
│                                         │
│  Selected: Bored Ape #1234             │
│  Community: SuperPaymaster             │
│  Bonus: +3 reputation                  │
│                                         │
│  [Confirm Binding]  [Cancel]          │
└────────────────────────────────────────┘
```

---

## Phase 2: Activity Tracking Page

### Features

#### 2.1 Activity Timeline
```typescript
components/Activity/ActivityTimeline.tsx

┌────────────────────────────────────────┐
│  Activity History                      │
│  [All] [This Week] [This Month]        │
│                                         │
│  🕐 Today                               │
│  • 14:23 - Transaction in GameFi DAO   │
│  • 09:15 - Governance vote cast        │
│                                         │
│  🕐 Yesterday                           │
│  • 18:45 - Transaction in SuperPM      │
│  • 16:30 - NFT bound to GameFi DAO    │
│                                         │
│  🕐 Oct 26                             │
│  • 11:20 - Transaction in DeFi Hub     │
│                                         │
│  [Load More]                           │
└────────────────────────────────────────┘
```

#### 2.2 Activity Heatmap
```typescript
components/Activity/ActivityHeatmap.tsx

┌────────────────────────────────────────┐
│  Activity Heatmap (Last 90 days)       │
│                                         │
│  Mon  ░ ░ ░ ██ ░ ░ ░ ░ ░ ░ ░ ░ ░      │
│  Tue  ░ ░ ██ ░ ░ ░ ██ ░ ░ ░ ░ ░ ░      │
│  Wed  ██ ░ ░ ░ ░ ██ ░ ░ ░ ██ ░ ░ ░     │
│  Thu  ░ ░ ░ ░ ██ ░ ░ ██ ░ ░ ░ ██ ░     │
│  Fri  ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ██ ░ ░      │
│  Sat  ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░      │
│  Sun  ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░      │
│                                         │
│  Legend: ░ None  ░ 1-5  ██ 6-10  ██ 10+ │
│                                         │
│  Total Activities: 234                 │
│  Most Active Day: Wednesday (45)       │
│  Current Streak: 7 days                │
└────────────────────────────────────────┘
```

---

## Phase 3: Community Management

### For Community Operators

#### 3.1 Community Dashboard
```typescript
pages/CommunityDashboard.tsx

┌────────────────────────────────────────┐
│  Community: SuperPaymaster             │
│  [Edit Profile] [Settings]             │
│                                         │
│  📊 Overview                           │
│  • Total Members: 1,234                │
│  • Active Users (30d): 856             │
│  • Total Activities: 45,678            │
│  • Average Reputation: 24.5            │
│                                         │
│  📈 Growth Chart                       │
│  [Line chart showing member growth]    │
│                                         │
│  👥 Top Contributors                   │
│  1. Alice (Rep: 89, Activities: 567)   │
│  2. Bob (Rep: 76, Activities: 432)     │
│  3. Carol (Rep: 65, Activities: 389)   │
│                                         │
│  [View All Members]                    │
└────────────────────────────────────────┘
```

#### 3.2 Member Management
```typescript
components/Community/MemberList.tsx

┌────────────────────────────────────────┐
│  Members (1,234)                       │
│  [Search] [Filter by Rep] [Export]     │
│                                         │
│  ┌──────────────────────────────┐     │
│  │ Alice (0x1234...5678)        │     │
│  │ SBT #123 | Rep: 89           │     │
│  │ Joined: Jan 1, 2025          │     │
│  │ Last Activity: 2h ago        │     │
│  │ [View Profile] [Message]     │     │
│  └──────────────────────────────┘     │
│                                         │
│  ┌──────────────────────────────┐     │
│  │ Bob (0xabcd...efgh)          │     │
│  │ SBT #456 | Rep: 76           │     │
│  │ Joined: Feb 15, 2025         │     │
│  │ Last Activity: 5h ago        │     │
│  │ [View Profile] [Message]     │     │
│  └──────────────────────────────┘     │
└────────────────────────────────────────┘
```

---

## Phase 4: Advanced Features

### 4.1 Reputation Leaderboard
```typescript
components/Leaderboard/ReputationLeaderboard.tsx

┌────────────────────────────────────────┐
│  Reputation Leaderboard                │
│  [Global] [By Community] [This Week]   │
│                                         │
│  Rank  User          Reputation        │
│  ────────────────────────────────────  │
│  🥇 1   Alice         127              │
│  🥈 2   Bob           115              │
│  🥉 3   Carol         98               │
│  4     Dave          89               │
│  5     Eve           76               │
│  ...                                   │
│  127   You            45               │
│                                         │
│  [View More]                           │
└────────────────────────────────────────┘
```

### 4.2 Achievement Badges
```typescript
components/Achievements/BadgeDisplay.tsx

┌────────────────────────────────────────┐
│  Achievements & Badges                 │
│                                         │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ │
│  │  🏆  │ │  ⭐  │ │  🔥  │ │  🎯  │ │
│  │Early │ │Top   │ │7-Day│ │ 100  │ │
│  │Adopter│ │Contrib│ │Streak│ │Acts │ │
│  └──────┘ └──────┘ └──────┘ └──────┘ │
│                                         │
│  ┌──────┐ ┌──────┐ ┌──────┐           │
│  │  🏅  │ │  👑  │ │  🎖️  │           │
│  │5 NFTs│ │ DAO  │ │Multi│           │
│  │Bound │ │Leader│ │-Com │           │
│  └──────┘ └──────┘ └──────┘           │
│                                         │
│  Progress: 7/20 badges earned          │
│  [View All] [Share]                    │
└────────────────────────────────────────┘
```

---

## Implementation Plan

### Week 1: Core Components
- [ ] Setup routes: `/sbt`, `/activity`, `/community/:id`
- [ ] Create base layout and navigation
- [ ] Implement SBTCard component
- [ ] Implement CommunityList component
- [ ] Connect to The Graph for data fetching

### Week 2: GraphQL Integration
- [ ] Setup Apollo Client
- [ ] Create GraphQL queries
- [ ] Implement loading states
- [ ] Add error handling
- [ ] Cache optimization

### Week 3: Interactive Features
- [ ] NFT binding modal
- [ ] Activity timeline
- [ ] Reputation breakdown
- [ ] Real-time updates (polling)

### Week 4: Community Dashboard
- [ ] Community stats
- [ ] Member management
- [ ] Analytics charts
- [ ] Export functionality

### Week 5: Polish & Testing
- [ ] Responsive design
- [ ] Dark mode support
- [ ] E2E tests (Playwright)
- [ ] Performance optimization

---

## Tech Stack

```typescript
// Frontend Framework
- Next.js 14 (App Router)
- TypeScript
- Tailwind CSS
- shadcn/ui components

// Data Fetching
- Apollo Client (GraphQL)
- TanStack Query (REST fallback)
- SWR (real-time data)

// State Management
- Zustand (global state)
- React Context (local state)

// Blockchain
- wagmi (Ethereum hooks)
- viem (contract interactions)
- RainbowKit (wallet connection)

// Charts & Visualization
- Recharts (activity charts)
- D3.js (heatmap)
- Framer Motion (animations)
```

---

## File Structure

```
frontend/
├── src/
│   ├── app/
│   │   ├── sbt/
│   │   │   ├── page.tsx                 # Main SBT page
│   │   │   ├── [tokenId]/
│   │   │   │   ├── page.tsx             # Individual SBT view
│   │   │   │   └── activity/
│   │   │   │       └── page.tsx         # Activity timeline
│   │   │   └── loading.tsx
│   │   │
│   │   └── community/
│   │       ├── [address]/
│   │       │   ├── page.tsx             # Community dashboard
│   │       │   ├── members/
│   │       │   │   └── page.tsx
│   │       │   └── analytics/
│   │       │       └── page.tsx
│   │       └── register/
│   │           └── page.tsx
│   │
│   ├── components/
│   │   ├── SBT/
│   │   │   ├── SBTCard.tsx
│   │   │   ├── SBTAvatar.tsx
│   │   │   ├── CommunityList.tsx
│   │   │   ├── ReputationCard.tsx
│   │   │   └── NFTBindingModal.tsx
│   │   │
│   │   ├── Activity/
│   │   │   ├── ActivityTimeline.tsx
│   │   │   ├── ActivityHeatmap.tsx
│   │   │   └── ActivityCard.tsx
│   │   │
│   │   ├── Community/
│   │   │   ├── CommunityDashboard.tsx
│   │   │   ├── MemberList.tsx
│   │   │   └── StatsCard.tsx
│   │   │
│   │   └── Leaderboard/
│   │       ├── ReputationLeaderboard.tsx
│   │       └── BadgeDisplay.tsx
│   │
│   ├── lib/
│   │   ├── graphql/
│   │   │   ├── client.ts                # Apollo client
│   │   │   ├── queries.ts               # GraphQL queries
│   │   │   └── types.ts                 # Generated types
│   │   │
│   │   ├── contracts/
│   │   │   ├── mysbt.ts                 # Contract interactions
│   │   │   └── abi.ts                   # Contract ABIs
│   │   │
│   │   └── utils/
│   │       ├── reputation.ts            # Reputation calculations
│   │       └── formatting.ts            # Data formatting
│   │
│   └── hooks/
│       ├── useSBT.ts                    # SBT data hook
│       ├── useReputation.ts             # Reputation hook
│       ├── useActivity.ts               # Activity hook
│       └── useCommunity.ts              # Community hook
```

---

## Next Steps

1. **Immediate**: Create base pages and routing
2. **This Week**: Implement GraphQL client and queries
3. **Next Week**: Build core SBT components
4. **Month 1**: Complete Phase 1 & 2
5. **Month 2**: Phase 3 & 4 + testing

---

**Status**: Ready to implement
**Priority**: High (enables user interaction with MySBT v2.2)
**Estimated Time**: 4-5 weeks
**Dependencies**: MySBT v2.2 deployed, The Graph subgraph live
