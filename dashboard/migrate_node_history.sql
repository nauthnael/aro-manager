-- Migration: Fix node_history timestamp offset and deduplicate
--
-- PROBLEM: _maybe_save_history stored report.reward_yesterday with timestamp=NOW,
-- causing a 1-day label shift in the reward chart (bar "day D" showed day D-1 reward).
--
-- This migration:
--   1. Shifts all timestamps back 1 day (corrects the label offset)
--   2. Deduplicates: keeps 1 record per (node_id, date) with the highest reward_today
--   3. Removes zero/null reward records (post-restart noise)
--
-- IMPORTANT: Take a backup before running!
--   pg_dump -t node_history <dbname> > node_history_backup_$(date +%Y%m%d).sql
--
-- Run inside a transaction so you can ROLLBACK if something looks wrong.

BEGIN;

-- Step 1: Shift all timestamps back 1 day
UPDATE node_history
SET timestamp = timestamp - INTERVAL '1 day';

-- Step 2: Keep only the record with the highest reward_today per (node_id, calendar date).
-- Uses PostgreSQL DISTINCT ON: for each (node_id, date) group, picks the row with
-- the highest reward_today (DESC), breaking ties by lowest id (oldest record).
DELETE FROM node_history
WHERE id NOT IN (
    SELECT DISTINCT ON (node_id, DATE(timestamp)) id
    FROM node_history
    ORDER BY node_id, DATE(timestamp), reward_today DESC NULLS LAST, id ASC
);

-- Step 3: Remove records with zero or null reward (post-restart noise that survived step 2
-- only because every record for that day also had reward=0)
DELETE FROM node_history
WHERE reward_today IS NULL OR reward_today = 0;

-- Sanity check before committing — review these numbers:
SELECT
    COUNT(*)                         AS total_records,
    COUNT(DISTINCT node_id)          AS total_nodes,
    ROUND(COUNT(*)::numeric /
          NULLIF(COUNT(DISTINCT node_id), 0), 1) AS avg_records_per_node,
    MIN(DATE(timestamp))             AS earliest_date,
    MAX(DATE(timestamp))             AS latest_date
FROM node_history;

-- If the numbers look correct (avg ~1 record/node/day, latest_date = yesterday), run:
COMMIT;
-- Otherwise run: ROLLBACK;
