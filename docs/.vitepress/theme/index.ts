// 文档站主题：直接复用 VitePress 默认主题，只叠加一层配色覆盖（见 custom.css）。
// 不自定义布局：默认主题的侧边栏、本地搜索、本页目录与上一篇/下一篇已经够用，
// 自造布局只会多一处与 VitePress 版本耦合的维护面。

import DefaultTheme from 'vitepress/theme';
import './custom.css';

export default DefaultTheme;
