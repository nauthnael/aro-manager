interface Props {
  status: string | null
  isStale: boolean
}

const STATUS_CONFIG: Record<string, { label: string; cls: string }> = {
  Online:     { label: 'Online',      cls: 'bg-green-100 text-green-800' },
  Offline:    { label: 'Offline',     cls: 'bg-red-100 text-red-800' },
  NoInternet: { label: 'No Internet', cls: 'bg-yellow-100 text-yellow-800' },
  Unbound:    { label: 'Unbound',     cls: 'bg-purple-100 text-purple-800' },
}

export default function StatusBadge({ status, isStale }: Props) {
  if (isStale) {
    return (
      <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-500">
        Stale
      </span>
    )
  }
  const c = (status ? STATUS_CONFIG[status] : undefined) ?? { label: status ?? 'Unknown', cls: 'bg-gray-100 text-gray-600' }
  return (
    <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${c.cls}`}>
      {c.label}
    </span>
  )
}
