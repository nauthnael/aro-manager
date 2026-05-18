interface Stats {
  total: number
  online: number
  unbound: number
  proxy_expired?: number
  stale: number
  no_exit_ip_count?: number
  no_points_yesterday_count?: number
  no_points_avg_count?: number
  no_points_2days_count?: number
  renew_0points_count?: number
  ip_leak_count?: number
}

function Card({
  label,
  value,
  border,
  active,
  onClick,
}: {
  label: string
  value: number
  border: string
  active: boolean
  onClick: () => void
}) {
  return (
    <div
      onClick={onClick}
      className={`bg-white rounded-lg shadow px-3 py-3 border-l-4 ${border} cursor-pointer transition-all
        ${active ? 'ring-2 ring-offset-1 ring-blue-400' : 'hover:shadow-md'}`}
    >
      <p className="text-[10px] text-gray-500 uppercase tracking-wide leading-tight">{label}</p>
      <p className="text-2xl font-bold mt-1 text-gray-800">{value}</p>
    </div>
  )
}

interface Props {
  stats: Stats
  activeFilter: string | null
  onFilter: (f: string | null) => void
}

export default function StatsCards({ stats, activeFilter, onFilter }: Props) {
  const ipLeakCount = stats.ip_leak_count ?? 0

  const statusCards = [
    { key: null,            label: 'Total',         value: stats.total,               border: 'border-gray-400' },
    { key: 'Online',        label: 'Online',        value: stats.online,              border: 'border-green-500' },
    { key: 'proxy_expired', label: 'Proxy Expired', value: stats.proxy_expired ?? 0,  border: 'border-orange-500' },
    { key: 'no_exit_ip',    label: 'Cần Active',    value: stats.no_exit_ip_count ?? 0, border: 'border-red-500' },
    { key: 'Unbound',       label: 'Unbound',       value: stats.unbound,             border: 'border-purple-500' },
    { key: 'stale',         label: 'VPS Offline',   value: stats.stale,               border: 'border-gray-400' },
  ]

  const filterCards = [
    { key: 'noPointsYesterday', label: 'Không điểm hôm qua', value: stats.no_points_yesterday_count ?? 0, border: 'border-yellow-500' },
    { key: 'noPointsAvg',       label: 'TB 0 điểm',          value: stats.no_points_avg_count ?? 0,       border: 'border-red-400' },
    { key: 'noPoints2Days',     label: 'Mất điểm 2 ngày',    value: stats.no_points_2days_count ?? 0,     border: 'border-red-600' },
    { key: 'renew0pts',         label: 'Renew 0 điểm',       value: stats.renew_0points_count ?? 0,       border: 'border-violet-600' },
  ]

  return (
    <div className="space-y-2">
      <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
        {statusCards.map(c => (
          <Card
            key={String(c.key)}
            label={c.label}
            value={c.value}
            border={c.border}
            active={activeFilter === c.key}
            onClick={() => onFilter(activeFilter === c.key ? null : c.key)}
          />
        ))}
      </div>
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        {filterCards.map(c => (
          <Card
            key={String(c.key)}
            label={c.label}
            value={c.value}
            border={c.border}
            active={activeFilter === c.key}
            onClick={() => onFilter(activeFilter === c.key ? null : c.key)}
          />
        ))}
      </div>
      {ipLeakCount > 0 && (
        <div
          onClick={() => onFilter(activeFilter === 'ip_leak' ? null : 'ip_leak')}
          className={`flex items-center gap-3 rounded-lg border-l-4 border-red-600 bg-red-50 px-4 py-3 shadow cursor-pointer transition-all
            ${activeFilter === 'ip_leak' ? 'ring-2 ring-offset-1 ring-red-400' : 'hover:shadow-md'}`}
        >
          <span className="text-xl">🚨</span>
          <div>
            <p className="text-xs font-semibold text-red-700 uppercase tracking-wide">IP Leak Detected</p>
            <p className="text-sm text-red-600">
              <span className="font-bold text-lg">{ipLeakCount}</span> node{ipLeakCount > 1 ? 's' : ''} đang lộ IP thật — ARO đã bị kill
            </p>
          </div>
        </div>
      )}
    </div>
  )
}
