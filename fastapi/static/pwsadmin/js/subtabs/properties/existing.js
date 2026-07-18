export function mount(context) {
  context.root.dataset.subtabMounted = 'true';
}

export function onShow(context) {
  context.sharedState.activeSubtabs[context.tabKey] = context.subtabKey;
}

export function onHide(context) {
  context.root.dataset.subtabHidden = 'true';
}

