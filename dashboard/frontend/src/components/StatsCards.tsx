interface Stats {
  total: number
  online: number
  offline: number
  no_internet: number
  unbound: number
  stale: number
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
      className={`bg-white rounded-lg shadow p-4 border-l-4 ${border} cursor-pointer transition-all
        ${active ? 'ring-2 ring-offset-1 ring-blue-400' : 'hover:shadow-md'}`}
    >
      <p className="text-xs text-gray-500 uppercase tracking-wide">{label}</p>
      <p className="text-3xl font-bold mt-1 text-gray-800">{value}</p>
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
    { key: null,          label: 'Total',       value: stats.total,       border: 'border-gray-400' },
    { key: 'Online',      label: 'Online',      value: stats.online,      border: 'border-green-500' },
    { key: 'Offline',     label: 'Offline',     value: stats.offline,     border: 'border-red-500' },
    { key: 'NoInternet',  label: 'No Internet', value: stats.no_internet,  border: 'border-yellow-500' },
    { key: 'Unbound',     label: 'Unbound',     value: stats.unbound,     border: 'border-purple-500' },
    { key: 'stale',       label: 'VPS Offline', value: stats.stale,       border: 'border-gray-400' },
  ]

  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-4">
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
