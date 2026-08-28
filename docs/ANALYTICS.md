# The analytics dashboard

The judge-facing dashboard lives in ClickHouse Cloud's native **Dashboards** surface. The
database views in `clickhouse/005_demo_seed.sql` are its stable panel contracts; keeping the
queries there makes the dashboard reproducible without maintaining a second web application or
giving a browser direct database credentials.

## Create the dashboard

Create a dashboard named **Show Up — Live Analytics** against the `show-up` service. Add these
panels:

### Funnel — horizontal bar

```sql
SELECT stage, users, conversion_percent
FROM demo_funnel_summary
ORDER BY stage_order
```

- Dimension: `stage`
- Value: `users`

### Daily activity — line

```sql
SELECT day, active_users, events
FROM demo_daily_activity
ORDER BY day
```

- X axis: `day`
- Series: `active_users`, `events`

### Profile segments — stacked bar

```sql
SELECT city, energy, profiles
FROM demo_profile_segments
ORDER BY city, energy
```

- X axis: `city`
- Stack/series: `energy`
- Value: `profiles`

### Corpus size — table or number tiles

```sql
SELECT 'Profiles' AS metric, count() AS value FROM profile_vectors
UNION ALL
SELECT 'Venues', count() FROM venue_vectors
UNION ALL
SELECT 'Events', count() FROM events
UNION ALL
SELECT 'CDC tables', count()
FROM system.tables
WHERE database = currentDatabase()
  AND name IN (
      'profiles', 'groups', 'group_members', 'rsvps', 'messages',
      'venue_options', 'venue_votes', 'reflections', 'attendance_votes',
      'contact_selections'
  )
```

### Venue corpus — bar

```sql
SELECT taxonomy_primary AS category, count() AS venues
FROM venue_vectors FINAL
GROUP BY category
ORDER BY venues DESC
LIMIT 12
```

## Why native ClickHouse dashboards

The dashboard is part of the ClickHouse evidence for the hackathon, not a parallel frontend
product. Native panels show that the visualizations execute against the same service that owns the
million-profile corpus and CDC replica, while the database views keep chart-specific presentation
metadata out of the analytical model.

The Supabase `analytics` function remains useful as a narrow programmatic read endpoint for the
mobile product, but it is not the dashboard renderer.
