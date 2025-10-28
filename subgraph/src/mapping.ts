// MySBT v2.2 - The Graph Event Mappings
// Event-driven activity tracking for reputation calculation

import { BigInt, Bytes, log } from "@graphprotocol/graph-ts";
import {
  SBTMinted,
  MembershipAdded,
  MembershipDeactivated,
  ActivityRecorded,
  NFTBound,
  NFTUnbound,
} from "../generated/MySBT/MySBT";
import {
  SBT,
  Community,
  CommunityMembership,
  Activity,
  ReputationScore,
  WeeklyActivityStat,
  GlobalStat,
} from "../generated/schema";

// Constants
const ACTIVITY_WINDOW = 4; // 4 weeks
const BASE_REPUTATION = BigInt.fromI32(20);
const NFT_BONUS = BigInt.fromI32(3);
const ACTIVITY_BONUS = BigInt.fromI32(1);
const ONE_WEEK = BigInt.fromI32(604800); // 1 week in seconds

// Helper: Get or create GlobalStat
function getOrCreateGlobalStat(): GlobalStat {
  let stat = GlobalStat.load("global");
  if (!stat) {
    stat = new GlobalStat("global");
    stat.totalSBTs = 0;
    stat.totalCommunities = 0;
    stat.totalActivities = BigInt.zero();
    stat.totalMemberships = 0;
    stat.lastUpdatedAt = BigInt.zero();
  }
  return stat;
}

// Helper: Get or create Community
function getOrCreateCommunity(address: Bytes): Community {
  let community = Community.load(address.toHexString());
  if (!community) {
    community = new Community(address.toHexString());
    community.memberCount = 0;
    community.save();

    let stat = getOrCreateGlobalStat();
    stat.totalCommunities++;
    stat.save();
  }
  return community;
}

// Handler: SBT Minted
export function handleSBTMinted(event: SBTMinted): void {
  let sbt = new SBT(event.params.tokenId.toString());
  sbt.holder = event.params.user;
  sbt.firstCommunity = event.params.firstCommunity;
  sbt.mintedAt = event.params.timestamp;
  sbt.totalCommunities = 1;
  sbt.save();

  let stat = getOrCreateGlobalStat();
  stat.totalSBTs++;
  stat.lastUpdatedAt = event.block.timestamp;
  stat.save();

  log.info("SBT #{} minted for user {}", [
    event.params.tokenId.toString(),
    event.params.user.toHexString(),
  ]);
}

// Handler: Membership Added
export function handleMembershipAdded(event: MembershipAdded): void {
  let membershipId = event.params.tokenId
    .toString()
    .concat("-")
    .concat(event.params.community.toHexString());

  let membership = new CommunityMembership(membershipId);
  membership.sbt = event.params.tokenId.toString();
  membership.community = event.params.community.toHexString();
  membership.joinedAt = event.params.timestamp;
  membership.isActive = true;
  membership.metadata = event.params.metadata;
  membership.activityCount = 0;
  membership.lastActivityTime = null;
  membership.save();

  // Update SBT total communities
  let sbt = SBT.load(event.params.tokenId.toString());
  if (sbt) {
    sbt.totalCommunities++;
    sbt.save();
  }

  // Update Community member count
  let community = getOrCreateCommunity(event.params.community);
  community.memberCount++;
  community.save();

  // Update global stats
  let stat = getOrCreateGlobalStat();
  stat.totalMemberships++;
  stat.lastUpdatedAt = event.block.timestamp;
  stat.save();

  log.info("Membership added: SBT #{} joined community {}", [
    event.params.tokenId.toString(),
    event.params.community.toHexString(),
  ]);
}

// Handler: Membership Deactivated
export function handleMembershipDeactivated(event: MembershipDeactivated): void {
  let membershipId = event.params.tokenId
    .toString()
    .concat("-")
    .concat(event.params.community.toHexString());

  let membership = CommunityMembership.load(membershipId);
  if (membership) {
    membership.isActive = false;
    membership.save();

    // Update Community member count
    let community = Community.load(event.params.community.toHexString());
    if (community) {
      community.memberCount--;
      community.save();
    }

    log.info("Membership deactivated: SBT #{} left community {}", [
      event.params.tokenId.toString(),
      event.params.community.toHexString(),
    ]);
  }
}

// Handler: Activity Recorded (CORE FUNCTION)
export function handleActivityRecorded(event: ActivityRecorded): void {
  let activityId = event.transaction.hash
    .toHexString()
    .concat("-")
    .concat(event.logIndex.toString());

  let activity = new Activity(activityId);
  activity.sbt = event.params.tokenId.toString();
  activity.community = event.params.community.toHexString();
  activity.membership = event.params.tokenId
    .toString()
    .concat("-")
    .concat(event.params.community.toHexString());
  activity.week = event.params.week;
  activity.timestamp = event.params.timestamp;
  activity.blockNumber = event.block.number;
  activity.transactionHash = event.transaction.hash;
  activity.save();

  // Update membership activity stats
  let membershipId = event.params.tokenId
    .toString()
    .concat("-")
    .concat(event.params.community.toHexString());
  let membership = CommunityMembership.load(membershipId);
  if (membership) {
    membership.activityCount++;
    membership.lastActivityTime = event.params.timestamp;
    membership.save();
  }

  // Update weekly activity stats
  let weeklyStatId = event.params.tokenId
    .toString()
    .concat("-")
    .concat(event.params.community.toHexString())
    .concat("-")
    .concat(event.params.week.toString());

  let weeklyStat = WeeklyActivityStat.load(weeklyStatId);
  if (!weeklyStat) {
    weeklyStat = new WeeklyActivityStat(weeklyStatId);
    weeklyStat.sbt = event.params.tokenId.toString();
    weeklyStat.community = event.params.community.toHexString();
    weeklyStat.week = event.params.week;
    weeklyStat.activityCount = 0;
    weeklyStat.firstActivityTime = event.params.timestamp;
  }
  weeklyStat.activityCount++;
  weeklyStat.lastActivityTime = event.params.timestamp;
  weeklyStat.save();

  // Calculate and store updated reputation score
  calculateAndStoreReputation(
    event.params.tokenId,
    event.params.community,
    event.params.timestamp,
    event.params.week
  );

  // Update global stats
  let stat = getOrCreateGlobalStat();
  stat.totalActivities = stat.totalActivities.plus(BigInt.fromI32(1));
  stat.lastUpdatedAt = event.block.timestamp;
  stat.save();

  log.info("Activity recorded: SBT #{} in community {} at week {}", [
    event.params.tokenId.toString(),
    event.params.community.toHexString(),
    event.params.week.toString(),
  ]);
}

// Handler: NFT Bound
export function handleNFTBound(event: NFTBound): void {
  // Update reputation score with NFT bonus
  calculateAndStoreReputation(
    event.params.tokenId,
    event.params.community,
    event.params.timestamp,
    event.params.timestamp.div(ONE_WEEK)
  );

  log.info("NFT bound: SBT #{} bound NFT {} in community {}", [
    event.params.tokenId.toString(),
    event.params.nftContract.toHexString(),
    event.params.community.toHexString(),
  ]);
}

// Handler: NFT Unbound
export function handleNFTUnbound(event: NFTUnbound): void {
  // Update reputation score without NFT bonus
  calculateAndStoreReputation(
    event.params.tokenId,
    event.params.community,
    event.params.timestamp,
    event.params.timestamp.div(ONE_WEEK)
  );

  log.info("NFT unbound: SBT #{} unbound NFT {} from community {}", [
    event.params.tokenId.toString(),
    event.params.nftContract.toHexString(),
    event.params.community.toHexString(),
  ]);
}

// Helper: Calculate and store reputation score
function calculateAndStoreReputation(
  tokenId: BigInt,
  community: Bytes,
  timestamp: BigInt,
  currentWeek: BigInt
): void {
  let scoreId = tokenId
    .toString()
    .concat("-")
    .concat(community.toHexString())
    .concat("-")
    .concat(timestamp.toString());

  let score = new ReputationScore(scoreId);
  score.sbt = tokenId.toString();
  score.community = community.toHexString();
  score.baseScore = BASE_REPUTATION;
  score.nftBonus = BigInt.zero(); // TODO: Query NFTBinding from contract
  score.activityBonus = BigInt.zero();
  score.calculatedAt = timestamp;
  score.activityWindow = ACTIVITY_WINDOW;

  // Calculate activity bonus from last N weeks
  let activityWeeks = 0;
  for (let i = 0; i < ACTIVITY_WINDOW; i++) {
    let weekToCheck = currentWeek.minus(BigInt.fromI32(i));
    let weeklyStatId = tokenId
      .toString()
      .concat("-")
      .concat(community.toHexString())
      .concat("-")
      .concat(weekToCheck.toString());

    let weeklyStat = WeeklyActivityStat.load(weeklyStatId);
    if (weeklyStat && weeklyStat.activityCount > 0) {
      activityWeeks++;
    }
  }

  score.activityBonus = BigInt.fromI32(activityWeeks).times(ACTIVITY_BONUS);
  score.score = score.baseScore.plus(score.nftBonus).plus(score.activityBonus);
  score.save();

  log.info("Reputation calculated: SBT #{} in community {} = {} (base:{} nft:{} activity:{})", [
    tokenId.toString(),
    community.toHexString(),
    score.score.toString(),
    score.baseScore.toString(),
    score.nftBonus.toString(),
    score.activityBonus.toString(),
  ]);
}
