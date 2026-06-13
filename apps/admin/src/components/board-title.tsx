import { Link } from 'react-router';
import { theme, Space } from 'antd';

// Sider brand. A small green "豆" mark + wordmark, collapsing to just the mark.
// PendingBot 中文代号「大绿豆」—— 绿点呼应品牌。
export function BoardTitle({ collapsed }: { collapsed: boolean }) {
  const { token } = theme.useToken();
  const mark = (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: 28,
        height: 28,
        borderRadius: 8,
        background: token.colorPrimary,
        color: '#fff',
        fontWeight: 700,
        fontSize: 16,
        flex: '0 0 auto',
      }}
    >
      豆
    </span>
  );
  return (
    <Link
      to="/"
      style={{ display: 'inline-flex', alignItems: 'center', textDecoration: 'none' }}
    >
      {collapsed ? (
        mark
      ) : (
        <Space size={8} align="center">
          {mark}
          <span style={{ fontWeight: 700, fontSize: 16, color: token.colorText }}>
            PendingBot Board
          </span>
        </Space>
      )}
    </Link>
  );
}
