import { lazy, Suspense } from 'react'
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'

const Login = lazy(() => import('./pages/Login'))
const Dashboard = lazy(() => import('./pages/Dashboard'))
const NodeDetail = lazy(() => import('./pages/NodeDetail'))
const AccountStats = lazy(() => import('./pages/AccountStats'))
const Settings = lazy(() => import('./pages/Settings'))
const ErrorStats = lazy(() => import('./pages/ErrorStats'))
const ProxyStats = lazy(() => import('./pages/ProxyStats'))
const RenewNodes = lazy(() => import('./pages/RenewNodes'))

function PrivateRoute({ children }: { children: React.ReactNode }) {
  return localStorage.getItem('token') ? <>{children}</> : <Navigate to="/login" replace />
}

const PageFallback = () => (
  <div className="min-h-screen flex items-center justify-center text-gray-400 text-sm">Đang tải...</div>
)

export default function App() {
  return (
    <BrowserRouter>
      <Suspense fallback={<PageFallback />}>
      <Routes>
        <Route path="/login" element={<Login />} />
        <Route path="/" element={<PrivateRoute><Dashboard /></PrivateRoute>} />
        <Route path="/nodes/:nodeId" element={<PrivateRoute><NodeDetail /></PrivateRoute>} />
        <Route path="/accounts" element={<PrivateRoute><AccountStats /></PrivateRoute>} />
        <Route path="/errors" element={<PrivateRoute><ErrorStats /></PrivateRoute>} />
        <Route path="/proxy-stats" element={<PrivateRoute><ProxyStats /></PrivateRoute>} />
        <Route path="/settings" element={<PrivateRoute><Settings /></PrivateRoute>} />
        <Route path="/renew" element={<PrivateRoute><RenewNodes /></PrivateRoute>} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      </Suspense>
    </BrowserRouter>
  )
}
