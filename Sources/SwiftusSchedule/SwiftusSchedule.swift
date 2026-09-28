/// SwiftusSchedule：会话本地持久提醒（规格 S8）。
///
/// 提醒写进会话事件流（`schedule/change`），提供 schedule_create / schedule_list /
/// schedule_delete 三个工具，并在到期后把提醒交付回同一会话。
///
/// 成员：SessionSchedule（服务）/ ScheduleRuntime（到期交付运行时）/
/// provideSessionSchedule / provideScheduleRuntime / provideScheduleTools（装配）/
/// 时间基础（formatUtcInstant / tryParseUtcInstant / resolveAtTarget …）/
/// 折叠（foldScheduleEvents）与到期决策（dueDecision）/ framing 渲染。
///
/// 时钟一律注入（SessionSchedule.clock / ScheduleRuntimeConfig.clock / wakeClock），
/// 模块不直读系统时钟（测试策略硬要求）。
