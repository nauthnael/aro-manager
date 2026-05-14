import { useEffect, useState } from 'react'
import { useQuery, useMutation } from '@tanstack/react-query'
import { MessageCircle, AlertTriangle, XCircle, WifiOff, RefreshCw } from 'lucide-react'
import api from '../api/client'

type TelegramHealth = {
  status: 'ok' | 'rate_limited' | 'error' | 'not_configured'
  bot_username: string | null
  retry_after: number
  error: string | null
}

export default function TelegramHealthBanner() {
  const [countdown, setCountdown] = useState(0)

  const { data, refetch, isFetching } = useQuery<TelegramHealth>({
    queryKey: ['telegram-health'],
    queryFn: () => api.get('/settings/telegram-health').then(r => r.data),
    refetchInterval: (query) => {
      const status = query.state.data?.status
      return status === 'rate_limited' ? 10_000 : 60_000
    },
  })

  const checkNow = useMutation({
    mutationFn: () => api.post('/settings/telegram-health/check').then(r => r.data),
    onSuccess: () => refetch(),
  })

  // Live countdown when rate limited
  useEffect(() => {
    if (data?.status !== 'rate_limited') { setCountdown(0); return }
    setCountdown(data.retry_after ?? 0)
    const id = setInterval(() => {
      setCountdown(prev => {
        if (prev <= 1) { clearInterval(id); refetch(); return 0 }
        return prev - 1
      })
    }, 1000)
    return () => clearInterval(id)
  }, [data?.status, data?.retry_after]) // eslint-disable-line react-hooks/exhaustive-deps

  if (!data || data.status === 'not_configured') return null

  const configs = {
    ok: {
      bar: 'bg-green-50 border-green-200',
      dot: 'bg-green-500',
      icon: <MessageCircle size={14} className="text-green-600 shrink-0" />,
      label: `Telegram API: Hoạt động bình thường${data.bot_username ? ` · ${data.bot_username}` : ''}`,
      labelCls: 'text-green-800',
    },
    rate_limited: {
      bar: 'bg-yellow-50 border-yellow-300',
      dot: 'bg-yellow-500 animate-pulse',
      icon: <AlertTriangle size={14} className="text-yellow-600 shrink-0" />,
      label: `Telegram API bị rate limit (429)${countdown > 0 ? ` · hết hạn sau ${countdown}s` : ''}`,
      labelCls: 'text-yellow-800',
    },
    error: {
      bar: 'bg-red-50 border-red-300',
      dot: 'bg-red-500',
      icon: <XCircle size={14} className="text-red-600 shrink-0" />,
      label: `Telegram API lỗi${data.error ? `: ${data.error}` : ''}`,
      labelCls: 'text-red-800',
    },
  } as const

  const cfg = configs[data.status as keyof typeof configs]
  if (!cfg) return null

  const isChecking = checkNow.isPending || isFetching

  return (
    <div className={`flex items-center gap-2.5 px-4 py-2 rounded-xl border text-sm ${cfg.bar}`}>
      <span className={`w-2 h-2 rounded-full shrink-0 ${cfg.dot}`} />
      {cfg.icon}
      <span className={`flex-1 font-medium truncate ${cfg.labelCls}`}>{cfg.label}</span>
      {data.status === 'rate_limited' && (
        <span className="text-xs text-yellow-600 bg-yellow-100 border border-yellow-200 px-2 py-0.5 rounded-full whitespace-nowrap">
          <WifiOff size={10} className="inline mr-1" />
          Thông báo tạm dừng
        </span>
      )}
      <button
        onClick={() => checkNow.mutate()}
        disabled={isChecking}
        className="flex items-center gap-1 px-2.5 py-1 text-xs text-gray-500 hover:text-gray-700 hover:bg-white border border-transparent hover:border-gray-200 rounded-lg transition-colors disabled:opacity-40 shrink-0"
        title="Kiểm tra ngay"
      >
        <RefreshCw size={11} className={isChecking ? 'animate-spin' : ''} />
        Kiểm tra
      </button>
    </div>
  )
}
