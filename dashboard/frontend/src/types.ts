export interface TagRef {
  id: number
  name: string
  color: string
}

export interface TagOut {
  id: number
  name: string
  color: string
  node_count: number
}

export interface NodeStatus {
  node_id: string
  aro_status: string | null
  proxy_ok: boolean | null
  reward_today: number | null
  reward_yesterday: number | null
  total_score: number | null
  avg_score: number | null
  uptime_ratio: number | null
  public_ip: string | null
  script_version: string | null
  last_seen: string | null
  is_stale: boolean
  account: string | null
  serial: string | null
  proxy_host: string | null
  proxy_port: number | null
  proxy_user: string | null
  notes: string | null
  first_seen: string | null
  renew_count: number
  needs_renew: boolean
  country_code: string | null
  tags: TagRef[]
}

export interface NodeListResponse {
  nodes: NodeStatus[]
  total: number
  total_filtered: number
  page: number
  page_size: number
  total_pages: number
  online: number
  offline: number
  no_internet: number
  unbound: number
  stale: number
  needs_renew_count: number
}

export interface HistoryPoint {
  timestamp: string
  aro_status: string | null
  reward_today: number | null
  uptime_ratio: number | null
}

export interface RestartEvent {
  id: number
  node_id: string
  timestamp: string
  success: boolean
  duration_secs: number | null
}

export interface NodeDetailResponse {
  node: NodeStatus
  history: HistoryPoint[]
  restart_events: RestartEvent[]
  node_log_stale_restart_minutes: number | null
  global_log_stale_restart_minutes: number
}

export interface AccountStats {
  account: string
  total: number
  online: number
  offline: number
  no_internet: number
  unbound: number
  vps_offline: number
  total_points: number
  avg_uptime: number | null
}

export interface Command {
  id: number
  node_id: string
  action: string
  status: string
  result: string | null
  created_at: string
  acked_at: string | null
  completed_at: string | null
  created_by: string | null
}

export type ErrorType = 'vps_offline' | 'aro_offline' | 'no_internet' | 'unbound' | 'proxy_fail'

export const ERROR_LABELS: Record<ErrorType, string> = {
  vps_offline: 'VPS Offline',
  aro_offline:  'ARO Offline',
  no_internet:  'ARO No Internet',
  unbound:      'Unbound',
  proxy_fail:   'Proxy Fail',
}

export const ERROR_COLORS: Record<ErrorType, string> = {
  vps_offline: '#ef4444',   // red
  aro_offline:  '#f97316',  // orange
  no_internet:  '#eab308',  // yellow
  unbound:      '#8b5cf6',  // violet
  proxy_fail:   '#64748b',  // slate
}

export interface ErrorEvent {
  id: number
  error_type: ErrorType
  started_at: string
  ended_at: string | null
  duration_minutes: number
  ongoing: boolean
}

export interface DailyScore {
  date: string
  score: number
  error_count: number
  vps_offline_minutes: number
  aro_offline_minutes: number
  no_internet_minutes: number
  unbound_minutes: number
  proxy_fail_minutes: number
}

export interface NodeErrorStats {
  node_id: string
  account: string | null
  today_score: number
  today_error_count: number
  avg_7d: number | null
  avg_30d: number | null
  errors_by_type: Partial<Record<ErrorType, number>>
  total_errors: number
  daily_scores: { date: string; score: number }[]
}

export interface ErrorStatsResponse {
  nodes: NodeErrorStats[]
  score_base: number
}

export interface RecentErrorEvent {
  id: number
  node_id: string
  error_type: ErrorType
  started_at: string
  ended_at: string | null
  duration_minutes: number
  ongoing: boolean
  proxy_host: string | null
  proxy_port: number | null
  proxy_user: string | null
}

export interface RecentEventsResponse {
  events: RecentErrorEvent[]
}

export interface ProxyStat {
  proxy_key: string
  proxy_display: string
  proxy_host: string | null
  proxy_user: string | null
  node_count: number
  node_ids: string[]
  total_errors: number
  proxy_down_count: number
  errors_by_type: Partial<Record<ErrorType, number>>
  total_score: number
}

export interface ProxyStatsResponse {
  proxies: ProxyStat[]
  days: number
}

export interface RenewCandidate {
  node_id: string
  account: string | null
  serial: string | null
  aro_status: string | null
  avg_score: number | null
  uptime_ratio: number | null
  last_seen: string | null
  is_stale: boolean
  renew_count: number
  last_renewed_at: string | null
  last_renew_status: string | null
  cooldown_until: string | null
}

export interface RenewCandidatesResponse {
  nodes: RenewCandidate[]
  total: number
}

export interface RenewLog {
  id: number
  node_id: string
  account: string | null
  renewed_at: string
  serial_before: string | null
  serial_after: string | null
  account_before: string | null
  command_id: number | null
  status: string
  renew_count: number
  monitored_at: string | null
  reward_yesterday: number | null
}

export interface RenewHistoryResponse {
  logs: RenewLog[]
  total: number
  page: number
  page_size: number
  total_pages: number
}

export interface NodeAccountHistory {
  id: number
  node_id: string
  account: string
  first_seen: string
  last_seen: string
}
