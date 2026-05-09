export interface NodeStatus {
  node_id: string
  aro_status: string | null
  proxy_ok: boolean | null
  reward_today: number | null
  reward_yesterday: number | null
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

export interface NodeDetailResponse {
  node: NodeStatus
  history: HistoryPoint[]
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
