export function mount(context) {
  context.root.dataset.moduleMounted = 'true';
}

export function onShow(context) {
  context.sharedState.activeTab = context.tabKey;
}

export function onHide(context) {
  context.root.dataset.moduleHidden = 'true';
}

