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
  const cards = [
    { key: null,                  label: 'Total',              value: stats.total,                        border: 'border-gray-400' },
    { key: 'Online',              label: 'Online',             value: stats.online,                       border: 'border-green-500' },
    { key: 'proxy_expired',       label: 'Proxy Expired',      value: stats.proxy_expired ?? 0,           border: 'border-orange-500' },
    { key: 'no_exit_ip',          label: 'Cần Active',         value: stats.no_exit_ip_count ?? 0,        border: 'border-red-500' },
    { key: 'Unbound',             label: 'Unbound',            value: stats.unbound,                      border: 'border-purple-500' },
    { key: 'stale',               label: 'VPS Offline',        value: stats.stale,                        border: 'border-gray-400' },
    { key: 'noPointsYesterday',   label: 'Không điểm hôm qua', value: stats.no_points_yesterday_count ?? 0, border: 'border-yellow-500' },
    { key: 'noPointsAvg',         label: 'TB 0 điểm',          value: stats.no_points_avg_count ?? 0,     border: 'border-red-400' },
    { key: 'noPoints2Days',       label: '0 điểm 2 ngày',      value: stats.no_points_2days_count ?? 0,   border: 'border-red-600' },
  ]

  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 xl:grid-cols-9 gap-3">
      {cards.map(c => (
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
  )
}
