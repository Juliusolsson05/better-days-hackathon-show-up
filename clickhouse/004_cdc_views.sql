-- ClickPipes models Postgres UPDATE/DELETE as versioned inserts. Reading a raw cdc_* table without
-- FINAL can double-count old versions until background merges finish; ignoring the delete marker
-- resurrects rows Postgres has already removed. These views make the correct current-state read
-- the default so every dashboard query does not need to rediscover both rules.

CREATE OR REPLACE VIEW analytics_profiles_current AS
SELECT id, tags, city, availability, embedded_at, created_at
FROM cdc_profiles FINAL
WHERE _peerdb_is_deleted = 0;

CREATE OR REPLACE VIEW analytics_groups_current AS
SELECT id, event_at, activity, seed_distance, created_at, chosen_venue_id,
       matching_run_key, event_timezone, venue_status, chat_opened_at
FROM cdc_groups FINAL
WHERE _peerdb_is_deleted = 0;

CREATE OR REPLACE VIEW analytics_group_members_current AS
SELECT group_id, user_id, joined_at, matching_run_key
FROM cdc_group_members FINAL
WHERE _peerdb_is_deleted = 0;

CREATE OR REPLACE VIEW analytics_rsvps_current AS
SELECT group_id, user_id, status
FROM cdc_rsvps FINAL
WHERE _peerdb_is_deleted = 0;

CREATE OR REPLACE VIEW analytics_messages_current AS
SELECT id, group_id, user_id, created_at, kind
FROM cdc_messages FINAL
WHERE _peerdb_is_deleted = 0;

CREATE OR REPLACE VIEW analytics_venue_options_current AS
SELECT id, group_id, position, provider_id, kind, locality, score
FROM cdc_venue_options FINAL
WHERE _peerdb_is_deleted = 0;

CREATE OR REPLACE VIEW analytics_venue_votes_current AS
SELECT group_id, user_id, option_id, voted_at
FROM cdc_venue_votes FINAL
WHERE _peerdb_is_deleted = 0;

CREATE OR REPLACE VIEW analytics_reflections_current AS
SELECT group_id, user_id, about_user, was_fallback
FROM cdc_reflections FINAL
WHERE _peerdb_is_deleted = 0;

CREATE OR REPLACE VIEW analytics_attendance_votes_current AS
SELECT group_id, voter_id, subject_id, showed_up
FROM cdc_attendance_votes FINAL
WHERE _peerdb_is_deleted = 0;

CREATE OR REPLACE VIEW analytics_contact_selections_current AS
SELECT group_id, selector_id, selected_id, created_at
FROM cdc_contact_selections FINAL
WHERE _peerdb_is_deleted = 0;

-- This is deliberately a view over current projections rather than another denormalized sink.
-- The source tables are tiny today, and keeping the lifecycle computation declarative means a
-- changed product rule cannot leave a permanently stale materialized interpretation behind.
CREATE OR REPLACE VIEW analytics_group_lifecycle AS
SELECT
    groups.id AS group_id,
    groups.event_at,
    groups.activity,
    groups.seed_distance,
    groups.venue_status,
    coalesce(members.member_count, 0) AS member_count,
    coalesce(rsvps.confirmed_count, 0) AS confirmed_count,
    coalesce(chat.user_message_count, 0) AS user_message_count,
    coalesce(chat.speaking_member_count, 0) AS speaking_member_count,
    coalesce(venue.vote_count, 0) AS venue_vote_count,
    coalesce(reflections.answer_count, 0) AS reflection_count,
    coalesce(attendance.attended_member_count, 0) AS attended_member_count,
    coalesce(contacts.mutual_pair_count, 0) AS mutual_contact_pair_count
FROM analytics_groups_current AS groups
LEFT JOIN (
    SELECT group_id, uniqExact(user_id) AS member_count
    FROM analytics_group_members_current
    GROUP BY group_id
) AS members ON members.group_id = groups.id
LEFT JOIN (
    SELECT group_id, countIf(status = 'confirmed') AS confirmed_count
    FROM analytics_rsvps_current
    GROUP BY group_id
) AS rsvps ON rsvps.group_id = groups.id
LEFT JOIN (
    SELECT group_id,
           countIf(kind = 'user') AS user_message_count,
           uniqExactIf(user_id, kind = 'user') AS speaking_member_count
    FROM analytics_messages_current
    GROUP BY group_id
) AS chat ON chat.group_id = groups.id
LEFT JOIN (
    SELECT group_id, uniqExact(user_id) AS vote_count
    FROM analytics_venue_votes_current
    GROUP BY group_id
) AS venue ON venue.group_id = groups.id
LEFT JOIN (
    SELECT group_id, uniqExact(user_id) AS answer_count
    FROM analytics_reflections_current
    GROUP BY group_id
) AS reflections ON reflections.group_id = groups.id
LEFT JOIN (
    SELECT group_id, countIf(votes >= 2 AND positive_votes * 2 >= votes) AS attended_member_count
    FROM (
        SELECT group_id, subject_id, count() AS votes, countIf(showed_up) AS positive_votes
        FROM analytics_attendance_votes_current
        GROUP BY group_id, subject_id
    )
    GROUP BY group_id
) AS attendance ON attendance.group_id = groups.id
LEFT JOIN (
    SELECT left_choice.group_id, count() AS mutual_pair_count
    FROM analytics_contact_selections_current AS left_choice
    INNER JOIN analytics_contact_selections_current AS right_choice
       ON right_choice.group_id = left_choice.group_id
      AND right_choice.selector_id = left_choice.selected_id
      AND right_choice.selected_id = left_choice.selector_id
    WHERE left_choice.selector_id < left_choice.selected_id
    GROUP BY left_choice.group_id
) AS contacts ON contacts.group_id = groups.id;
