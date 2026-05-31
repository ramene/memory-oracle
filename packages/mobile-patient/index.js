import { registerRootComponent } from 'expo';
import App from './App';

// SDK 54+ requires explicit AppRegistry registration.
// registerRootComponent calls AppRegistry.registerComponent('main', () => App)
// and wraps the app appropriately for Expo Go and standalone builds.
registerRootComponent(App);
