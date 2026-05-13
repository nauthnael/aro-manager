export interface NodeStatus {
  node_id: string
  aro_status: string | null
  proxy_ok: boolean | null
  reward_today: number | null
  reward_yesterday: number | null
  total_score: number | null
  uptime_ratio: number | null
  public_ip: string | null
  script_version: string | null
  last_seen: string | null
  is_stale: boolean
  account: string | null
  serial: string | null
  proxy_host: string | null
  proxy_port: number | null
  notes: string | null
}

export interface NodeListResponse {
  nodes: NodeStatus[]
  total: number
  online: number
  offline: number
  no_internet: number
  unbound: number
  stale: number
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
  no_internet:  'No Internet',
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
