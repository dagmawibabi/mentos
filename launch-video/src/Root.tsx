import { Composition } from "remotion";
import { Launch, launchDuration } from "./Launch";

export const RemotionRoot: React.FC = () => {
  return (
    <Composition
      id="MentosLaunch"
      component={Launch}
      durationInFrames={launchDuration(30)}
      fps={30}
      width={1920}
      height={1080}
    />
  );
};
