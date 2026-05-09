import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { BarChart2, LogOut, RefreshCw, Settings } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { NodeListResponse } from '../types'
import api from '../api/client'
import StatsCards from '../components/StatsCards'
import NodeTable from '../components/NodeTable'

export default function Dashboard() {
  const navigate = useNavigate()
  const [statusFilter, setStatusFilter] = useState<string | null>(null)
  const [search, setSearch] = useState('')

  const params = new URLSearchParams()
  if (statusFilter) params.set('status_filter', statusFilter)
  if (search) params.set('search', search)

  const { data, isLoading, refetch, dataUpdatedAt, isFetching } = useQuery<NodeListResponse>({
    queryKey: ['nodes', statusFilter, search],
    queryFn: () => api.get(`/dashboard/nodes?${params}`).then(r => r.data),
    refetchInterval: 30_000,
  })

  const logout = () => {
    localStorage.removeItem('token')
    navigate('/login')
  }

  const handleFilter = (f: string | null) => {
    setStatusFilter(f)
    setSearch('')
  }

  const handleSearch = (v: string) => {
    setSearch(v)
    setStatusFilter(null)
  }

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white border-b border-gray-200 sticky top-0 z-10">
        <div className="max-w-screen-2xl mx-auto px-4 py-3 flex items-center justify-between">
          <div>
            <h1 className="text-lg font-bold text-gray-800">ARO Dashboard</h1>
            <p className="text-xs text-gray-400">
              {dataUpdatedAt
                ? `Cập nhật lúc ${new Date(dataUpdatedAt).toLocaleTimeString('vi-VN')} · tự refresh 30s`
                : 'Đang tải...'}
            </p>
          </div>
          <div className="flex items-center gap-1">
            <button
              onClick={() => navigate('/accounts')}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm text-gray-600 hover:text-gray-900 hover:bg-gray-100 rounded-lg transition-colors"
              title="Thống kê theo Account"
            >
              <BarChart2 size={15} />
              <span className="hidden sm:inline">Thống kê Account</span>
            </button>
            <button
              onClick={() => navigate('/settings')}
              className="flex items-center gap-1.5 px-3 py-1.5 text-sm text-gray-600 hover:text-gray-900 hover:bg-gray-100 rounded-lg transition-colors"
              title="Cài đặt"
            >
              <Settings size={15} />
              <span className="hidden sm:inline">Cài đặt</span>
            </button>
            <button
              onClick={() => refetch()}
              disabled={isFetching}
              className="p-2 text-gray-500 hover:text-gray-800 disabled:opacity-40 transition-colors"
              title="Refresh"
            >
              <RefreshCw size={16} className={isFetching ? 'animate-spin' : ''} />
            </button>
            <button
              onClick={logout}
              className="p-2 text-gray-500 hover:text-gray-800 transition-colors"
              title="Đăng xuất"
            >
              <LogOut size={16} />
            </button>
          </div>
        </div>
      </header>

      <main className="max-w-screen-2xl mx-auto px-4 py-5 space-y-5">
        {data && (
          <StatsCards stats={data} activeFilter={statusFilter} onFilter={handleFilter} />
        )}

        <div className="flex items-center gap-3 flex-wrap">
          <input
            type="text"
            placeholder="Tìm theo hostname hoặc account..."
            value={search}
            onChange={e => handleSearch(e.target.value)}
            className="flex-1 min-w-[200px] border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
          />
          {statusFilter && (
            <button
              onClick={() => setStatusFilter(null)}
              className="px-3 py-2 text-sm bg-blue-50 text-blue-700 border border-blue-200 rounded-lg hover:bg-blue-100 transition-colors"
            >
              Filter: {statusFilter} ✕
            </button>
          )}
          <span className="text-sm text-gray-400 whitespace-nowrap">
            {data?.nodes.length ?? 0} / {data?.total ?? 0} nodes
          </span>
        </div>

        {isLoading ? (
          <div className="text-center py-20 text-gray-400">Đang tải danh sách node...</div>
        ) : (
          <NodeTable nodes={data?.nodes ?? []} />
        )}
      </main>
    </div>
  )
}
