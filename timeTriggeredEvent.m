classdef timeTriggeredEvent
    properties
        nextTrigger; % Next time event is going to be invoked
        triggersLog=[]; % Log of event invocation times
        eventMethod; % Event to invoke
    end
    methods
        function obj=timeTriggeredEvent(em,nt)
            % obj=timeTriggeredEvent(em,nt)
            %
            % First parameter is name of function to be called when event
            % is triggered, second parameter is time of next trigger of
            % event
            obj.eventMethod=em;
            obj.nextTrigger=nt;
        end
        function outData=checkAndExecute(obj,currTime,inData)
            if currTime>=obj.nextTrigger
                outData=feval(obj.eventMethod,inData);
            else
                outData=inData;
            end
        end
    end
end